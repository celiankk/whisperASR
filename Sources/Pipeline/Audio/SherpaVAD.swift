import Foundation
import SherpaONNX

// MARK: - Silero VAD 封装（SherpaVAD）
//
// 神经网络人声活动检测（sherpa-onnx v1.13.6 C API 内置，LiveTranslate
// Silero VAD 对标）：对「能量高但非人声」的音频（音乐底噪 / 掌声 /
// 电子音 / 高频嘶声）的判别力显著优于 RMS+ZCR 启发式。
//
// 定位（与 Pipeline/VAD/VAD.swift 的关系）：
// - RMS+ZCR 是零成本主判据（每轮循环都跑）；
// - 本类是可选增强判据：模型可用时为 ASRManager 的静音跳过/封口
//   判定提供人声概率；模型缺失时上层回落纯启发式（行为不变）。
// - 不替代封口切点计算（lastSilenceCut / lowestEnergyCut 保持）。
//
// 模型文件：Models/silero_vad.onnx（~2.2MB，MIT），设置页手动下载；
// 未下载时 isAvailable=false，全部查询安全回落。

/// Silero VAD 会话封装（单线程 CPU 推理，~0.5ms/窗口）。
final class SherpaVAD: @unchecked Sendable {
    /// 模型文件名（ModelCatalog.modelDirectory 下）。
    static let modelFileName = "silero_vad.onnx"

    static let shared = SherpaVAD()

    private var detector: OpaquePointer?
    private let lock = NSLock()
    /// 加载失败后不再重试的时间戳（避免每轮循环反复读盘/建会话）。
    private var lastLoadFailure: Date = .distantPast
    /// 喂音水位线：已喂入的总采样数（调用方传绝对区间时按此裁增量）。
    /// Silero 是流式状态机——重复喂已喂过的音频浪费推理且让实时态
    /// 被旧音频反复刷新；调用方（ASRManager 循环）每轮传同一 tail 区间，
    /// 内部只喂新增采样。reset() 清零（新录制会话）。
    private var fedSampleCount = 0

    private init() {}

    static var modelURL: URL {
        ModelCatalog.modelDirectory.appendingPathComponent(modelFileName)
    }

    /// 模型文件是否已在磁盘上（设置页显示用）。
    static var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// VAD 是否可用（模型已就绪且会话已建立）。
    var isAvailable: Bool {
        lock.withLock { ensureLoadedLocked() }
    }

    /// 喂入音频并返回「当前是否检测到人声」。
    /// 模型不可用返回 nil（调用方回落启发式判定）。
    /// - Parameters:
    ///   - samples: 16kHz 单声道 PCM（任意长度，内部按 512 窗口切）。
    ///   - absoluteStart: samples 在录制时间轴上的起始采样位置；提供时
    ///     内部按喂音水位线裁剪，只喂纯新增采样（tail 重访零重复推理）。
    ///     nil = 全量喂入（调用方无法提供位置时）。
    ///
    /// 本封装只用 Detected() 的实时语音态判定，不消费语音段输出——
    /// 每次查询后 Flush + Clear 清空内部段队列：否则检测到的段在
    /// circular buffer 无限堆积（长录制内存泄漏），队列满后 Detected()
    /// 语义漂移。
    func detectSpeech(_ samples: [Float], absoluteStart: Int? = nil) -> Bool? {
        guard !samples.isEmpty else { return nil }
        return lock.withLock { () -> Bool? in
            guard ensureLoadedLocked(), let detector else { return nil }
            // 增量裁剪：调用方给绝对位置时跳过已喂区间（水位线之前）。
            let feed: ArraySlice<Float>
            if let absoluteStart {
                let newStart = max(0, fedSampleCount - absoluteStart)
                guard newStart < samples.count else {
                    // 全部已喂过：只刷新实时态（不重复推理）。
                    let detected = SherpaOnnxVoiceActivityDetectorDetected(detector) == 1
                    SherpaOnnxVoiceActivityDetectorFlush(detector)
                    SherpaOnnxVoiceActivityDetectorClear(detector)
                    return detected
                }
                feed = samples[newStart...]
                fedSampleCount = absoluteStart + samples.count
            } else {
                feed = samples[...]
                fedSampleCount += samples.count
            }
            // 按 512 窗口步进喂入（Silero 输入窗 @16kHz = 32ms）。
            feed.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset + 512 <= feed.count {
                    SherpaOnnxVoiceActivityDetectorAcceptWaveform(
                        detector, base + offset, 512)
                    offset += 512
                }
            }
            let detected = SherpaOnnxVoiceActivityDetectorDetected(detector) == 1
            // 丢弃段输出（只要实时态）：flush 收口当前段、clear 清队列。
            SherpaOnnxVoiceActivityDetectorFlush(detector)
            SherpaOnnxVoiceActivityDetectorClear(detector)
            return detected
        }
    }

    /// 复位会话状态（新录制会话开始时；丢弃内部缓冲的段队列与喂音水位线）。
    func reset() {
        lock.withLock {
            if let detector {
                SherpaOnnxVoiceActivityDetectorClear(detector)
                SherpaOnnxVoiceActivityDetectorFlush(detector)
            }
            fedSampleCount = 0
        }
    }

    /// 懒加载（锁内调用）：模型存在才建会话；60s 冷却防失败风暴。
    private func ensureLoadedLocked() -> Bool {
        if detector != nil { return true }
        guard Date().timeIntervalSince(lastLoadFailure) > 60 else { return false }
        let url = Self.modelURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        var config = SherpaOnnxVadModelConfig()
        config.sample_rate = 16000
        config.num_threads = 1
        let provider = dup("cpu")
        config.provider = UnsafePointer(provider)
        let modelPath = dup(url.path)
        config.silero_vad.model = UnsafePointer(modelPath)
        config.silero_vad.threshold = 0.5
        config.silero_vad.min_silence_duration = 0.5
        config.silero_vad.min_speech_duration = 0.25
        config.silero_vad.max_speech_duration = 15.0
        config.silero_vad.window_size = 512

        guard let created = SherpaOnnxCreateVoiceActivityDetector(&config, 30.0) else {
            modelPath.deallocate()
            provider.deallocate()
            lastLoadFailure = Date()
            AppLogger.shared.log(.asr, "SherpaVAD: failed to create detector (model \(url.path))")
            return false
        }
        modelPath.deallocate()
        provider.deallocate()
        detector = created
        AppLogger.shared.log(.asr, "SherpaVAD: detector ready (silero_vad.onnx)")
        return true
    }
}

/// C 字符串拷贝辅助（与 SherpaONNXRuntime 同模式）。
private func dup(_ s: String) -> UnsafeMutablePointer<CChar> {
    strdup(s)!
}
