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

    /// 从 GGUF 文件读取 "general.architecture"（找不到或解析失败返回 nil）。
    static func architecture(atPath path: String) -> String? {
        guard let data = readHeader(path: path) else { return nil }
        var cursor = 0

        // magic + version + tensor_count + n_kv
        guard data.count >= 4 + 4 + 8,
              data.readUInt32(at: &cursor) == 0x4655_4747 else { return nil }
        _ = data.readUInt32(at: &cursor)   // version
        _ = data.readUInt64(at: &cursor)   // tensor_count
        _ = data.readUInt64(at: &cursor)   // n_kv

        // 解析元数据 KV（只找 general.architecture，通常第一个就是）。
        let maxKeys = 8
        for _ in 0..<maxKeys {
            guard let key = data.readString(at: &cursor),
                  let rawType = data.readUInt32(at: &cursor),
                  let type = ValueType(rawValue: rawType) else { return nil }

            switch type {
            case .string:
                if key == "general.architecture" {
                    return data.readString(at: &cursor)
                }
                guard data.skipString(at: &cursor) else { return nil }
            case .uint8, .int8, .bool:
                guard data.skipBytes(1, at: &cursor) else { return nil }
            case .uint16, .int16:
                guard data.skipBytes(2, at: &cursor) else { return nil }
            case .uint32, .int32, .float32:
                guard data.skipBytes(4, at: &cursor) else { return nil }
            case .uint64, .int64, .float64:
                guard data.skipBytes(8, at: &cursor) else { return nil }
            case .array:
                guard data.skipArray(at: &cursor) else { return nil }
            }
        }
        return nil
    }

    private static func readHeader(path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // 前 64KB 足够覆盖所有元数据键；超出部分不需要。
        return try? handle.read(upToCount: 64 * 1024)
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
