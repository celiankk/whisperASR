import Foundation

// MARK: - GGUF 头解析器
//
// 读取 GGUF 文件头部的 "general.architecture" 元数据，用于在不依赖文件名的
// 情况下识别模型架构（例如自定义路径上传的 Qwen3-ASR GGUF）。
//
// GGUF v3 布局（小端）：
//   magic        : u32 = 0x46554747 ("GGUF")
//   version      : u32
//   tensor_count : u64
//   n_kv         : u64（元数据键值对数量）
//   元数据 KV 列表：
//     key        : u64 长度 + bytes
//     value_type : u32
//     value      : 按类型
//   tensor_info 列表（无需解析）

enum GGUFInspector {
    fileprivate enum ValueType: UInt32 {
        case uint8 = 0, int8 = 1, uint16 = 2, int16 = 3, uint32 = 4, int32 = 5
        case float32 = 6, bool = 7, string = 8, array = 9, uint64 = 10, int64 = 11, float64 = 12
    }

    /// 首次读取窗口（原实现值：多数模型的 general.architecture 就在最前面）。
    private static let initialWindowBytes = 64 * 1024
    /// 读取窗口上限：只读文件头、绝不整文件读入，4MB 对任何 GGUF 头都够。
    private static let maxWindowBytes = 4 * 1024 * 1024
    /// KV 扫描上限：此前只扫前 8 个键，architecture 靠后（如 Qwen3-ASR 的
    /// 量化/分词器键在前）就直接放弃 → 回落 whisper → whisper.cpp 加载
    /// GGUF 失败。64 个键配合按需增长的窗口足以覆盖现实模型头。
    private static let maxKeys = 64

    /// 头解析结果：区分「确实没有 general.architecture」与「当前窗口读不完
    /// KV 列表」——后者需要扩大窗口重试，不是失败。
    private enum Outcome {
        case found(String)
        case notFound
        /// 数据窗口不足（KV 尚未读完）。调用方扩大窗口重读。
        case truncated
    }

    /// 从 GGUF 文件读取 "general.architecture"（找不到或解析失败返回 nil）。
    /// 读取窗口按需增长（64KB → 4MB）：只扩大文件头读取量，不做整文件读入，
    /// 也不引入大内存分配；失败（含非法头）仍安全返回 nil 由调用方回落。
    static func architecture(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var window = initialWindowBytes
        while true {
            guard let data = try? handle.read(upToCount: window), !data.isEmpty else { return nil }
            switch parse(data) {
            case .found(let arch):
                return arch
            case .notFound:
                return nil
            case .truncated:
                // 窗口内没读完：文件已到底（读到的比请求的少）或已达上限就放弃。
                guard data.count == window, window < maxWindowBytes else { return nil }
                window = min(window * 4, maxWindowBytes)
                do { try handle.seek(toOffset: 0) } catch { return nil }
            }
        }
    }

    private static func parse(_ data: Data) -> Outcome {
        var cursor = 0

        // magic + version + tensor_count + n_kv
        guard data.count >= 4 + 4 + 8,
              data.readUInt32(at: &cursor) == 0x4655_4747 else { return .notFound }
        _ = data.readUInt32(at: &cursor)   // version
        _ = data.readUInt64(at: &cursor)   // tensor_count
        _ = data.readUInt64(at: &cursor)   // n_kv

        // 解析元数据 KV（只找 general.architecture）。
        // 读取/跳过失败一律按「窗口不足」处理：由调用方扩大窗口重试，
        // 上限封顶 → 畸形文件只是多读几次头，不会无限增长或误判。
        for _ in 0..<maxKeys {
            guard let key = data.readString(at: &cursor),
                  let rawType = data.readUInt32(at: &cursor),
                  let type = ValueType(rawValue: rawType) else { return .truncated }

            switch type {
            case .string:
                if key == "general.architecture" {
                    guard let arch = data.readString(at: &cursor) else { return .truncated }
                    return .found(arch)
                }
                guard data.skipString(at: &cursor) else { return .truncated }
            case .uint8, .int8, .bool:
                guard data.skipBytes(1, at: &cursor) else { return .truncated }
            case .uint16, .int16:
                guard data.skipBytes(2, at: &cursor) else { return .truncated }
            case .uint32, .int32, .float32:
                guard data.skipBytes(4, at: &cursor) else { return .truncated }
            case .uint64, .int64, .float64:
                guard data.skipBytes(8, at: &cursor) else { return .truncated }
            case .array:
                guard data.skipArray(at: &cursor) else { return .truncated }
            }
        }
        return .notFound
    }
}

// MARK: - 小端读取辅助

private extension Data {
    func readUInt32(at cursor: inout Int) -> UInt32? {
        guard cursor + 4 <= count else { return nil }
        defer { cursor += 4 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
    }

    func readUInt64(at cursor: inout Int) -> UInt64? {
        guard cursor + 8 <= count else { return nil }
        defer { cursor += 8 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) }
    }

    func readString(at cursor: inout Int) -> String? {
        guard let length = readUInt64(at: &cursor), length <= 1_048_576,
              cursor + Int(length) <= count else { return nil }
        defer { cursor += Int(length) }
        return String(data: subdata(in: cursor..<(cursor + Int(length))), encoding: .utf8)
    }

    func skipString(at cursor: inout Int) -> Bool {
        guard let length = readUInt64(at: &cursor), cursor + Int(length) <= count else { return false }
        cursor += Int(length)
        return true
    }

    func skipBytes(_ n: Int, at cursor: inout Int) -> Bool {
        guard cursor + n <= count else { return false }
        cursor += n
        return true
    }

    /// 跳过数组值：u32 元素类型 + u64 元素数量 + 各元素。
    func skipArray(at cursor: inout Int) -> Bool {
        guard let elementType = readUInt32(at: &cursor),
              let count = readUInt64(at: &cursor),
              count <= 1_000_000 else { return false }

        func skipElement(_ type: UInt32) -> Bool {
            guard let t = GGUFInspector.ValueType(rawValue: type) else { return false }
            switch t {
            case .string: return skipString(at: &cursor)
            case .uint8, .int8, .bool: return skipBytes(1, at: &cursor)
            case .uint16, .int16: return skipBytes(2, at: &cursor)
            case .uint32, .int32, .float32: return skipBytes(4, at: &cursor)
            case .uint64, .int64, .float64: return skipBytes(8, at: &cursor)
            case .array: return skipArray(at: &cursor)
            }
        }
        for _ in 0..<Int(count) where !skipElement(elementType) {
            return false
        }
        return true
    }
}
