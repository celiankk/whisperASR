import Foundation

// MARK: - 会话级 Prefix KV Cache（流式 ASR 增量 Prefill）
//
// 设计文档：docs/prefix-kv-cache-design.md
//
// 分层：
//   KVCacheSession（本文件）——状态管理器：容量规划 / 淘汰决策 /
//     position_ids 与 attention_mask 的语义构建 / 增量追加簿记。
//     **纯逻辑、引擎无关、已单测**。
//   KVCacheBackend（协议）——物理缓存后端（MLX 统一内存预分配 K/V 池）。
//   MLXPrefillKVBackend（MLXKVBackend.swift）——MLX 骨架，canImport 守卫。
//
// 核心不变量（与设计文档 §3 对应）：
//   - 缓存中的 K/V 已在写入时应用对应位置的 RoPE → 增量 token 的
//     position_ids 必须自 cachedPrefixLength 连续自增（防错位）；
//   - 增量 Prefill 只前向新增 token：attention_mask 为「前缀区全 1 可
//     attend + 新区因果」，缓存区行不参与本轮计算（结果已固化在 K/V）；
//   - 会话与录制会话严格绑定：静音切段/换题/音频不连续（环形缓冲覆盖
//     丢弃）→ 安全 Evict（全量重建），杜绝跨不连续点的上下文幻觉。

// MARK: - 类型

/// 会话失效原因（决定安全 Evict 的处置方式）。
enum KVSessionInvalidationReason: Sendable, Equatable {
    /// 静音切段（SubtitleManager.sealSilence 后长静音）。
    case silenceSeal
    /// 用户换题（显式操作 / 转录相似度骤降）。
    case topicChange
    /// 音频流不连续（SPSC 环形缓冲覆盖丢弃——必须重置：缓存上下文已与真实流错位）。
    case streamDiscontinuity
    /// 上下文超限且单块新增超过保留目标（无法滑窗）。
    case contextOverflow
    /// 模型/引擎切换。
    case modelSwitch
}

/// 追加前的容量规划结论。
enum KVEvictionPlan: Equatable {
    /// 直接追加（缓存有余量）。
    case none
    /// 滑动窗口：裁掉最旧 `evictCount` 个 token。骨架实现走「重 Prefill
    /// 保留窗口」（正确性优先）；RoPE 旋转移位为后续优化项。
    case shiftWindow(evictCount: Int)
    /// 全量重建（清缓存后对新增内容重新 prefill）。
    case resetAll
}

/// 一次增量追加的回执（供日志/对账/解码步使用）。
struct KVAppendReceipt: Equatable {
    /// 本批 K/V 在物理缓存中的写入起点（绝对 token 位置）。
    let cacheOffset: Int
    /// 新增 token 的 position_ids（自 cachedPrefixLength 自增，RoPE 连续）。
    let positions: Range<Int>
    /// 新增每个 token 可 attend 的前缀长度（mask 行语义：
    /// 第 j 个新 token 可 attend [0, cacheOffset+j]，共 cacheOffset+j+1 个）。
    let attendableCounts: [Int]
    /// 本轮追加前是否先做了 reset / 滑窗重建（解码状态需同步复位）。
    let rebuiltFirst: Bool
}

/// 单 token 解码步回执。
struct KVDecodeReceipt: Equatable {
    /// 该 token 在缓存中的写入位置（= 追加前的 cachedPrefixLength）。
    let cacheOffset: Int
    /// 可 attend 的前缀长度（= 该位置，即全部历史 + 自身）。
    let attendableCount: Int
}

/// 新增 token 的 K/V（逐层；张量类型由后端模块定义）。
struct KVNewKV {
    let tokenCount: Int
    /// 每层一个 K 张量（布局由后端约定，如 [kvHeads, tokenCount, headDim]）。
    let k: [KVTensor]
    /// 每层一个 V 张量。
    let v: [KVTensor]
}

/// 物理缓存后端抽象：MLX / 未来 Core ML 导出均可实现。
protocol KVCacheBackend: AnyObject {
    /// 物理缓存容量上限（token 数；session 与 backend 必须一致）。
    var maxContextTokens: Int { get }

    /// 只前向新增 token，产出逐层 K/V。
    /// positions/mask 语义由 KVCacheSession 的静态构建函数给出。
    func computeNewKV(tokens: [Int],
                      positions: Range<Int>,
                      attendableCounts: [Int]) async throws -> KVNewKV

    /// 把 K/V 追加进物理缓存（写入位置 = offset，永不与已消费区重叠）。
    func write(offset: Int, kv: KVNewKV) throws

    /// 滑动窗口方案 2：清缓存后对保留窗口重新 prefill（无 RoPE 移位风险）。
    func reprefillWindow(tokenIDs: [Int]) async throws

    /// 全量复位物理缓存（统一内存内容清零/游标归位）。
    func resetAll()
}

// MARK: - 状态管理器

/// 会话级 Prefix KV Cache 状态管理器。
/// 生命周期与录制会话绑定：start 时创建、stop 时释放；
/// 跨会话不复用（与 SubtitleManager 的 clearMemory 纪律一致）。
///
/// 线程模型：实时转录循环串行调用（ASRManager 每 pass await），
/// 与 SubtitleManager 同级——不做内部加锁，靠调用方串行性保证。
final class KVCacheSession {

    /// 物理缓存上限（token 数）。
    let maxContextTokens: Int
    /// 触发滑窗裁剪后的保留目标（< maxContextTokens，留出增长余量避免频繁裁剪）。
    let keepTargetTokens: Int
    /// 物理后端。
    private let backend: KVCacheBackend

    /// 已缓存的 token 数（= cachedTokenIDs.count = 下一次追加的写入偏移）。
    private(set) var cachedPrefixLength = 0
    /// 已缓存 token 的 ID 序列（滑窗裁剪/诊断/重建窗口用）。
    private(set) var cachedTokenIDs: [Int] = []
    /// 缓存代际：每次 reset/滑窗重建递增——解码侧状态（如采样器、
    /// 已生成前缀）以此对账，代际不符即自身复位。
    private(set) var generation = 0

    /// 是否已被外部信号失效（待消费；消费即清除）。
    private var pendingInvalidation: KVSessionInvalidationReason?

    init(maxContextTokens: Int, keepTargetTokens: Int, backend: KVCacheBackend) {
        precondition(maxContextTokens > 0, "maxContextTokens must be positive")
        precondition(keepTargetTokens > 0 && keepTargetTokens < maxContextTokens,
                     "keepTargetTokens must be in (0, maxContextTokens)")
        precondition(backend.maxContextTokens >= maxContextTokens,
                     "backend capacity must cover session maxContextTokens")
        self.maxContextTokens = maxContextTokens
        self.keepTargetTokens = keepTargetTokens
        self.backend = backend
    }

    // MARK: 容量规划（纯函数；对应设计文档 §5）

    /// 追加 newTokenCount 个 token 前的淘汰决策。
    func planAppend(newTokenCount: Int) -> KVEvictionPlan {
        guard newTokenCount > 0 else { return .none }
        let projected = cachedPrefixLength + newTokenCount
        if projected <= maxContextTokens { return .none }
        // 超限：单块新增装得进保留目标 → 滑窗；否则只能全量重建。
        if newTokenCount <= keepTargetTokens {
            return .shiftWindow(evictCount: projected - keepTargetTokens)
        }
        return .resetAll
    }

    // MARK: mask / position 语义构建（纯函数；供后端与单测共用）

    /// 增量 token 的 position_ids：自 cachedPrefixLength 连续自增。
    /// RoPE 连续性关键：缓存 K/V 已带绝对位置旋转，偏移断档即错位。
    static func positions(afterCachedLength cachedLength: Int, newCount: Int) -> Range<Int> {
        cachedLength..<(cachedLength + newCount)
    }

    /// 增量 Prefill 的 attention mask 行语义（前缀区全 1 + 新区因果）：
    /// 第 j 个新 token 可 attend 前 cachedLength+j+1 个 token。
    static func attendableCounts(cachedLength: Int, newCount: Int) -> [Int] {
        (0..<newCount).map { cachedLength + $0 + 1 }
    }

    /// 解码步（单 token）的可 attend 长度：全部历史 + 自身。
    static func decodeAttendableCount(cachedLength: Int) -> Int {
        cachedLength + 1
    }

    // MARK: Forward Step（增量 Prefill）

    /// 增量 Prefill：只计算新增 token 的 K/V 并追加入池。
    ///
    /// 数据流（设计文档 §3.1）：规划淘汰 → （必要时重建）→ 构建位置/mask
    /// → 后端只前向新增 → 写入物理缓存 → 簿记推进。
    func prefillIncremental(_ newTokenIDs: [Int]) async throws -> KVAppendReceipt {
        // 失效信号懒生效：不打断当前 pass，下一次追加前清缓存。
        _ = consumeInvalidateIfPending()
        guard !newTokenIDs.isEmpty else {
            return KVAppendReceipt(cacheOffset: cachedPrefixLength,
                                   positions: cachedPrefixLength..<cachedPrefixLength,
                                   attendableCounts: [],
                                   rebuiltFirst: false)
        }
        precondition(newTokenIDs.count <= maxContextTokens,
                     "single prefill larger than maxContextTokens")

        var rebuiltFirst = false

        switch planAppend(newTokenCount: newTokenIDs.count) {
        case .none:
            break

        case .shiftWindow(let evictCount):
            // 骨架策略（文档 §5-A 方案 2）：重建保留窗口 = [旧缓存 + 新增]
            // 的末尾 keepTargetTokens。正确性优先——无 RoPE 移位风险；
            // 旋转移位（方案 1）作为后续优化替换此分支。
            AppLogger.shared.log(.ui, "[KVCache] sliding window evict=\(evictCount) keep=\(keepTargetTokens)")
            let window = Array((cachedTokenIDs + newTokenIDs).suffix(keepTargetTokens))
            try await backend.reprefillWindow(tokenIDs: window)
            cachedTokenIDs = window
            cachedPrefixLength = window.count
            generation += 1
            rebuiltFirst = true
            // 重建已包含新增 token → 本轮无需再前向，直接回执。
            return KVAppendReceipt(cacheOffset: 0,
                                   positions: 0..<window.count,
                                   attendableCounts: Self.attendableCounts(cachedLength: 0,
                                                                           newCount: window.count),
                                   rebuiltFirst: true)

        case .resetAll:
            backend.resetAll()
            cachedTokenIDs = []
            cachedPrefixLength = 0
            generation += 1
            rebuiltFirst = true
        }

        // 正常追加路径（.none 或 reset 后的首次写入）。
        let offset = cachedPrefixLength
        let positions = Self.positions(afterCachedLength: offset, newCount: newTokenIDs.count)
        let counts = Self.attendableCounts(cachedLength: offset, newCount: newTokenIDs.count)

        let kv = try await backend.computeNewKV(
            tokens: newTokenIDs, positions: positions, attendableCounts: counts)
        try backend.write(offset: offset, kv: kv)

        cachedTokenIDs.append(contentsOf: newTokenIDs)
        cachedPrefixLength += newTokenIDs.count

        return KVAppendReceipt(cacheOffset: offset,
                               positions: positions,
                               attendableCounts: counts,
                               rebuiltFirst: rebuiltFirst)
    }

    /// 解码步：单 token attend 全部缓存（mask 一行全 1）。
    /// 容量守卫：prefill 走 planAppend 淘汰，而两次 prefill 之间的连续
    /// decodeStep 也会推进游标——超限时抛语义化错误，解码循环据此触发
    /// 滑窗重建（reprefillWindow）或整段重 prefill，而非物理缓存越界。
    func decodeStep(_ tokenID: Int) async throws -> KVDecodeReceipt {
        _ = consumeInvalidateIfPending()
        let offset = cachedPrefixLength
        guard offset < maxContextTokens else {
            throw KVCacheError.capacityExceeded(needed: offset + 1,
                                                capacity: maxContextTokens)
        }
        let kv = try await backend.computeNewKV(
            tokens: [tokenID],
            positions: Self.positions(afterCachedLength: offset, newCount: 1),
            attendableCounts: [Self.decodeAttendableCount(cachedLength: offset)])
        try backend.write(offset: offset, kv: kv)
        cachedTokenIDs.append(tokenID)
        cachedPrefixLength += 1
        return KVDecodeReceipt(cacheOffset: offset,
                               attendableCount: Self.decodeAttendableCount(cachedLength: offset))
    }

    // MARK: 安全 Evict / 失效

    /// 外部信号触发的安全 Evict（设计文档 §5-B）：
    /// - `streamDiscontinuity`：环形缓冲覆盖丢弃后**必须**调用——缓存
    ///   上下文已与真实音频流错位，续用会产生幻觉；
    /// - `silenceSeal` / `topicChange`：按策略可配（连续同话题语音跨句
    ///   缓存仍有价值，默认仅提供机制不强制触发）。
    /// 失效立即生效于下一次追加（懒执行：不打断当前转录 pass）。
    func invalidate(_ reason: KVSessionInvalidationReason) {
        pendingInvalidation = reason
    }

    /// 消费待生效的失效信号（prefillIncremental 内部第一步调用）。
    private func consumeInvalidateIfPending() -> Bool {
        guard let reason = pendingInvalidation else { return false }
        pendingInvalidation = nil
        switch reason {
        case .contextOverflow:
            break   // 已由 planAppend 走专用路径
        default:
            backend.resetAll()
            cachedTokenIDs = []
            cachedPrefixLength = 0
            generation += 1
        }
        return true
    }
}
