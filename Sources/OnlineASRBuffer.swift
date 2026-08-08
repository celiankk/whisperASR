import Foundation

// MARK: - 在线音频缓冲（OnlineASRBuffer）
//
// 在线 API 句子模式（sentence mode）音频缓冲：
// 不直接发送实时短 chunk（0.5~3s 中途音频会返回"嗯"等碎片），
// 累计音频达到条件后才发送：
//
//   AudioManager → OnlineASRBuffer → 达到条件 → 发送 API
//
// 条件（默认）：
// - 累计 ≥ 目标时长（2.5s，范围 1.5~3s 可调）；
// - 或缓冲末尾检测到停顿（静音 ≥ 0.4s）——提前发送完整句；
// - 或超过上限（8s）——强制发送，防止无限累积。
//
// 低于最小发送长度（2s）不发送（minimumAudioDuration）。

final class OnlineASRBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstSampleDate: Date?

    /// 最小发送长度（低于不发送）。
    let minimumDuration: Double
    /// 目标累计时长。
    let targetDuration: Double
    /// 上限（超限强制发送）。
    let maxDuration: Double
    /// 停顿判定：末尾静音窗口（秒）。
    let silenceWindow: Double
    /// 停顿静音阈值（RMS）。
    let silenceThreshold: Float

    init(minimumDuration: Double = 2.0,
         targetDuration: Double = 2.5,
         maxDuration: Double = 8.0,
         silenceWindow: Double = 0.4,
         silenceThreshold: Float = 0.0015) {
        self.minimumDuration = minimumDuration
        self.targetDuration = targetDuration
        self.maxDuration = maxDuration
        self.silenceWindow = silenceWindow
        self.silenceThreshold = silenceThreshold
    }

    /// 追加音频（实时 chunk 持续累积）。
    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if samples.isEmpty {
            firstSampleDate = Date()
        }
        samples.append(contentsOf: newSamples)
    }

    /// 是否达到发送条件：达目标时长 / 末尾停顿 / 超上限。
    /// 未达最小发送长度时不发送（低于 2s 碎片音频直接丢弃语义）。
    func shouldSend(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let duration = Double(samples.count) / 16000.0
        guard duration >= minimumDuration else { return false }
        if duration >= targetDuration { return true }
        if duration >= maxDuration { return true }
        return hasSilencePauseLocked(duration: duration)
    }

    /// 取出全部样本并清空（发送前调用）。
    func takeAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let taken = samples
        samples.removeAll()
        firstSampleDate = nil
        return taken
    }

    /// 清空（停止/切换引擎时调用）。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        firstSampleDate = nil
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return samples.isEmpty
    }

    /// 当前缓冲时长（秒）。
    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / 16000.0
    }

    /// 末尾静音检测：最后 silenceWindow 秒 RMS 低于阈值 → 停顿。
    private func hasSilencePauseLocked(duration: Double) -> Bool {
        let windowSamples = Int(silenceWindow * 16000)
        guard samples.count >= windowSamples else { return false }
        let tail = samples.suffix(windowSamples)
        var sum: Float = 0
        for s in tail { sum += s * s }
        let rms = (sum / Float(windowSamples)).squareRoot()
        return rms < silenceThreshold
    }
}

// MARK: - 在线结果合并（OnlineResultAccumulator）
//
// 连续 API 返回的碎片（"嗯"、"我"、"觉得"、"这个"）不直接覆盖字幕：
// 累积合并 previousText + newText，直到一句完成（句末标点）才提交。
//
// 规则：
// - 无句末标点：累积，返回累积文本（作为 interim 显示）；
// - 句末标点（。？！.!?…）：提交完整句并清空。

final class OnlineResultAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated: String = ""
    private let terminators: Set<Character> = ["。", "？", "！", ".", "?", "!", "…", "～"]

    /// 合并新结果。
    /// - Returns: (合并后文本, 是否句完成)
    func merge(_ newText: String) -> (text: String, isComplete: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (accumulated, false) }
        // 拼接（中英文混合补空格）。
        accumulated = accumulated.isEmpty
            ? trimmed
            : accumulated + " " + trimmed
        if let last = accumulated.last, terminators.contains(last) {
            let completed = accumulated
            accumulated = ""
            return (completed, true)
        }
        return (accumulated, false)
    }

    /// 清空（停止/切换引擎时调用）。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        accumulated = ""
    }
}
