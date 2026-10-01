import Foundation

// MARK: - Chunk Manager（音频分片聚合器）

/// 统一音频分片聚合器（TranscriptionService 持有）：
///
///   Audio Input → Audio Buffer → Chunk Manager → ASR Provider → Subtitle Buffer
///
/// 规则：
/// - 累积时长 ≥ 最短识别时间 → 立即可发送；
/// - 否则等待，最长等待时间兜底强制发送；
/// - 上限保护：超过 `capacitySeconds` 丢弃最旧（防止取消/超时残留累积）。
///
/// 参数运行时从 AudioChunkingConfig 读取，设置修改立即生效。
/// 线程安全：仅 TranscriptionService 串行调用（实时循环逐轮 await），
/// 停止录制时 clear()。

final class ChunkManager: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    /// 队列首个样本的入队时间（聚合等待起算点）。
    private var firstSampleDate: Date?

    /// 容量上限（秒）：超限丢最旧。
    private let capacitySeconds: Double = 15

    /// 追加音频样本（最新的 chunk 优先：超限丢最旧）。
    /// 接收零拷贝切片（P0 链路：聚合入口不经 Array 构造）。
    func append(_ newSamples: ArraySlice<Float>) {
        lock.lock()
        defer { lock.unlock() }
        if samples.isEmpty {
            firstSampleDate = Date()
        }
        samples.append(contentsOf: newSamples)
        let capacitySamples = Int(capacitySeconds * 16000)
        if samples.count > capacitySamples {
            samples.removeFirst(samples.count - capacitySamples)
        }
    }

    /// 是否达到发送条件：时长达标 或 等待超时（参数实时读取）。
    func isReadyToSend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return durationLocked() >= AudioChunkingConfig.minChunkSeconds
            || ageLocked() >= AudioChunkingConfig.maxWaitSeconds
    }

    /// 当前累积时长（秒）。
    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return durationLocked()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return samples.isEmpty
    }

    /// 取出全部样本并清空（发送前调用）。
    ///
    /// 返回 `ArraySlice` 借用原缓冲（零拷贝）：用 swap 把内部数组的存储
    /// **整体移交**给调用方，再装上一个空数组——不复制样本、不清零缓冲。
    /// 为什么不是返回 `[Float]`：`let taken = samples; samples.removeAll()`
    /// 让 taken 与内部存储共享缓冲，removeAll 触发写时复制 → 每个 chunk
    /// 白拷一份（实时链路的 chunk 可达数百 KB）。调用方按切片消费
    ///（`dispatchChunk` 本就只接受 ArraySlice）。
    func takeAll() -> ArraySlice<Float> {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return [][...] }
        var taken: [Float] = []
        swap(&taken, &samples)
        firstSampleDate = nil
        return taken[...]
    }

    /// 清空（停止录制 / 切换引擎时调用，丢弃残留聚合）。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        firstSampleDate = nil
    }

    private func durationLocked() -> Double {
        Double(samples.count) / 16000.0
    }

    private func ageLocked() -> Double {
        guard let firstSampleDate else { return 0 }
        return Date().timeIntervalSince(firstSampleDate)
    }
}
