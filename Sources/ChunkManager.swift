import Foundation

// MARK: - 音频分片模式（AudioChunkingMode）
//
// 音频分片作为识别链路中的可控策略，统一三个模式管理，
// 避免每个 Provider 单独配置造成复杂度：
//
// - off：所有识别引擎关闭分片，保持 1.4 原实时识别流程；
// - localOnly：Whisper / Qwen / Nemotron 启用分片，Online API 跳过；
// - onlineOnly：Online ASR 启用分片，本地引擎跳过。
//
// 参数（最短识别时间 / 最长等待时间）只在分片开启时生效：
// - 最短识别时间：默认 3 秒，范围 1-10 秒；
// - 最长等待时间：默认 5 秒，范围 3-15 秒。

enum AudioChunkingMode: String, CaseIterable, Codable {
    case off
    case localOnly
    case onlineOnly

    static let key = "audioChunkingMode"

    var label: String {
        switch self {
        case .off: return "关闭"
        case .localOnly: return "仅本地模型"
        case .onlineOnly: return "仅在线 API"
        }
    }

    /// 说明文字（设置页展示应用范围）。
    var appliesToText: String {
        switch self {
        case .off: return ""
        case .localOnly: return "应用于：Whisper / Qwen / Nemotron"
        case .onlineOnly: return "应用于：Online ASR"
        }
    }

    /// 当前保存的模式。
    static var current: AudioChunkingMode {
        AudioChunkingMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .off
    }
}

/// 音频分片参数（UserDefaults 持久化；运行时读取，修改立即生效）。
enum AudioChunkingConfig {
    enum Keys {
        static let minSeconds = "audioChunkingMinSeconds"
        static let maxWaitSeconds = "audioChunkingMaxWaitSeconds"
    }

    static let minChunkRange = 1.0...10.0
    static let maxWaitRange = 3.0...15.0

    /// 最短识别时间（聚合发送下限，1-10 秒，默认 3）。
    static var minChunkSeconds: Double {
        let value = UserDefaults.standard.double(forKey: Keys.minSeconds)
        return minChunkRange.contains(value) ? value : 3
    }

    /// 最长等待时间（聚合发送兜底，3-15 秒，默认 5）。
    static var maxWaitSeconds: Double {
        let value = UserDefaults.standard.double(forKey: Keys.maxWaitSeconds)
        return maxWaitRange.contains(value) ? value : 5
    }
}

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
    func append(_ newSamples: [Float]) {
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
    func takeAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let taken = samples
        samples.removeAll()
        firstSampleDate = nil
        return taken
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
