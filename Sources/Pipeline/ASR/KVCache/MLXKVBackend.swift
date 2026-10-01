import Foundation

// MARK: - MLX 物理 KV 缓存后端（骨架）
//
// 数据布局（统一内存，init 一次预分配——设计文档 §7 内存公式）：
//   K/V 逐层：[kvHeads, maxContextTokens, headDim]（float16）
//   写游标 = cacheOffset（绝对 token 位置，与 KVCacheSession 簿记一致）
//
// 编译策略：`#if canImport(MLXNN)`——工程接入 mlx-swift 依赖后本文件的
// 真实实现参与编译；未接入时以「后端不可用」桩参与编译（协议占位、
// 显式抛错，保证骨架随主包持续编译、接口不腐化）。
//
// 状态：**骨架**——数据布局、接口签名与容量公式已定案；张量算子
//（宿主模型前向 / RoPE 旋转移位）待 mlx-swift 接入后填充并验证。

// MARK: 张量占位类型

#if canImport(MLXNN)
import MLX
import MLXNN

/// MLX 接入后：张量即 MLXArray。
typealias KVTensor = MLXArray
#else
/// MLX 未接入时的占位张量：只承载形状与可选原始值
///（测试 FakeBackend 用它验证编排逻辑；算子在真实后端内部实现）。
struct KVTensor: Equatable {
    var dims: [Int]
    var values: [Float] = []

    init(dims: [Int], values: [Float] = []) {
        self.dims = dims
        self.values = values
    }
}
#endif

/// 后端错误。
enum KVCacheError: Error, Equatable {
    case backendUnavailable(String)
    case capacityExceeded(needed: Int, capacity: Int)
}

// MARK: - 后端实现

#if canImport(MLXNN)

/// MLX 后端（骨架）。
final class MLXPrefillKVBackend: KVCacheBackend {
    let maxContextTokens: Int
    private let layerCount: Int
    private let kvHeads: Int
    private let headDim: Int

    /// 物理缓存池：逐层 [kvHeads, maxCtx, headDim]，float16 统一内存。
    private var kCache: [MLXArray]
    private var vCache: [MLXArray]

    /// - Note: 预分配发生在 init（会话建立期，非 RT 路径）。
    ///   例：24 层 × 8 kv 头 × 8192 ctx × 128 维 × 2(K+V) × 2B(f16)
    ///   ≈ 1.6GB——maxContextTokens 按设备档位收敛（设计文档 §7）。
    init(layerCount: Int, kvHeads: Int, headDim: Int, maxContextTokens: Int) {
        self.layerCount = layerCount
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.maxContextTokens = maxContextTokens
        kCache = (0..<layerCount).map { _ in
            MLXArray.zeros([kvHeads, maxContextTokens, headDim], dtype: .float16)
        }
        vCache = (0..<layerCount).map { _ in
            MLXArray.zeros([kvHeads, maxContextTokens, headDim], dtype: .float16)
        }
    }

    func computeNewKV(tokens: [Int],
                      positions: Range<Int>,
                      attendableCounts: [Int]) async throws -> KVNewKV {
        // 骨架：此处应调用宿主音频-LLM 模型的前向——
        //   audioEmbed(newFrames) + promptEmbed(tokens)
        //   → 逐层 attention(positions, mask) 时取出的新 K/V
        // 注意：RoPE 在 QK 内积前按 positions 旋转（与缓存写入时的
        // 绝对位置连续），缓存区张量原样复用、不重算。
        // 待 mlx-swift 模型实现后填充；当前显式抛错防止静默走错路径。
        throw KVCacheError.backendUnavailable("MLX host model forward not wired yet")
    }

    func write(offset: Int, kv: KVNewKV) throws {
        guard offset + kv.tokenCount <= maxContextTokens else {
            throw KVCacheError.capacityExceeded(needed: offset + kv.tokenCount,
                                                capacity: maxContextTokens)
        }
        // 骨架：逐层切片赋值（MLX 下标更新；物理内存在统一内存池内原地写）。
        for layer in 0..<layerCount {
            kCache[layer][0..., offset..<(offset + kv.tokenCount), 0...] = kv.k[layer]
            vCache[layer][0..., offset..<(offset + kv.tokenCount), 0...] = kv.v[layer]
        }
    }

    func reprefillWindow(tokenIDs: [Int]) async throws {
        // 骨架：清池后对窗口整段重新前向（滑窗方案 2，见设计文档 §5-A）。
        resetAll()
        // 待宿主模型实现：prefillWindow(tokenIDs) 写入 [0..<count)。
        throw KVCacheError.backendUnavailable("MLX host model forward not wired yet")
    }

    func resetAll() {
        kCache = (0..<layerCount).map { _ in
            MLXArray.zeros([kvHeads, maxContextTokens, headDim], dtype: .float16)
        }
        vCache = (0..<layerCount).map { _ in
            MLXArray.zeros([kvHeads, maxContextTokens, headDim], dtype: .float16)
        }
    }
}

#else

/// MLX 未接入时的占位后端：显式抛错，接口不腐化（主包持续可编译）。
final class MLXPrefillKVBackend: KVCacheBackend {
    let maxContextTokens: Int

    init(layerCount: Int, kvHeads: Int, headDim: Int, maxContextTokens: Int) {
        self.maxContextTokens = maxContextTokens
    }

    func computeNewKV(tokens: [Int],
                      positions: Range<Int>,
                      attendableCounts: [Int]) async throws -> KVNewKV {
        throw KVCacheError.backendUnavailable("mlx-swift 未接入（canImport(MLXNN) == false）")
    }

    func write(offset: Int, kv: KVNewKV) throws {
        throw KVCacheError.backendUnavailable("mlx-swift 未接入（canImport(MLXNN) == false）")
    }

    func reprefillWindow(tokenIDs: [Int]) async throws {
        throw KVCacheError.backendUnavailable("mlx-swift 未接入（canImport(MLXNN) == false）")
    }

    func resetAll() {
        // 桩：无物理缓存可清。
    }
}

#endif
