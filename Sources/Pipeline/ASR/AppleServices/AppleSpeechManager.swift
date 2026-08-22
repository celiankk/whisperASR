import Foundation
import Speech
import AVFoundation

// MARK: - Apple Speech Manager（AppleSpeechManager）
//
// Apple Speech 的 ASRProvider 适配层（统一注册到 TranscriptionService，
// ASRManager 经由 service 调度，不绕过 Manager）：
//
//   AudioCaptureManager → PCM Buffer → AppleSpeechManager
//                                            ↓
//   AppleSpeechEngine（SpeechAnalyzer / SpeechTranscriber / AnalysisContext）
//                                            ↓
//   ASRResult（统一输出：text / language / timestamp / confidence / isFinal）
//
// 实时链路（增量模式，兼容 AppState 循环）：
//   transcribeChunk 喂入流式会话 → 返回本次新增文本（partial 立即上字幕，
//   不等待 final）；final 由字幕链路进入翻译流程。
//
// 统一输出 ASRResult；Apple 模块不直接控制字幕。

/// Apple Speech 统一错误。
enum AppleSpeechError: LocalizedError {
    case notAuthorized
    case localeUnsupported(String)
    case initializationFailed(String)
    case recognitionFailed(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "语音识别未授权（系统设置 → 隐私与安全性 → 语音识别）"
        case .localeUnsupported(let locale):
            return "Apple Speech 不支持语言：\(locale)"
        case .initializationFailed(let msg):
            return "Apple Speech 初始化失败：\(msg)"
        case .recognitionFailed(let msg):
            return "Apple Speech 识别失败：\(msg)"
        case .unavailable(let msg):
            return "Apple Speech 不可用：\(msg)"
        }
    }
}

final class AppleSpeechManager: @unchecked Sendable, ASRProvider {
    /// 共享实例（TranscriptionService 与设置页状态查询共用同一引擎状态）。
    static let shared = AppleSpeechManager()

    var engine: ASRProviderEngine { .apple }

    // MARK: - 静态配置 / 能力

    static var localeIdentifier: String {
        ConfigurationManager.shared.asr.appleSpeechLocale
    }

    /// 已安装识别语言标识（菜单栏 Apple 语言包子菜单用；信号量等待
    /// 异步查询——调用频率低、XPC 单次 ~ms 级，主线程短暂阻塞可接受）。
    func installedLocaleIdentifiers() -> [String] {
        let sem = DispatchSemaphore(value: 0)
        var result: [String] = []
        Task {
            result = (await AppleLanguageManager.shared.installedLanguages())
                .map(\.identifier)
            sem.signal()
        }
        sem.wait()
        return result
    }

    static var authorizationStatus: AppleSpeechPermission.SpeechAuth {
        AppleSpeechPermission.speechAuth
    }

    static var isAuthorized: Bool {
        AppleSpeechPermission.isSpeechAuthorized
    }

    static var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AppleSpeechPermission.microphoneAuth
    }

    static func openSystemPermissionSettings() {
        AppleSpeechPermission.openSystemSettings()
    }

    // MARK: - 状态（设置页 / 系统状态页）

    /// 引擎状态描述（macOS 26+：AppleSpeechEngine 状态；<26 不可用）。
    var engineStateDescription: String {
        if #available(macOS 26, *) {
            if let engine = stateLock.withLock({ speechEngineStorage as? AppleSpeechEngine }) {
                return engine.state.rawValue
            }
            return "未启动"
        }
        return "需要 macOS 26+"
    }

    /// AppleSpeechDebug 统计摘要（设置页展示）。
    var debugStatsSummary: String {
        if #available(macOS 26, *) {
            guard let engine = stateLock.withLock({ speechEngineStorage as? AppleSpeechEngine }) else {
                return "engine not started"
            }
            return engine.stats.summary
        }
        return "unavailable"
    }

    // MARK: - 会话状态

    private let stateLock = NSLock()
    @available(macOS 26, *)
    private var speechEngine: AppleSpeechEngine? {
        get { stateLock.withLock { speechEngineStorage as? AppleSpeechEngine } }
        set { stateLock.withLock { speechEngineStorage = newValue } }
    }
    private var speechEngineStorage: Any?

    // MARK: - ASRProvider

    /// 预加载：授权 + 启动流式会话（SpeechTranscriber/SpeechAnalyzer/AnalysisContext）。
    /// 幂等：已有运行中的会话直接返回，不重复创建（避免旧 analyzer 泄漏）。
    func prepare() async throws {
        guard #available(macOS 26, *) else {
            throw AppleSpeechError.unavailable("Apple Speech 需要 macOS 26+")
        }
        if let existing = speechEngine, existing.isRunning {
            return
        }
        if let stale = speechEngine {
            await stale.stop()
            speechEngine = nil
        }
        try await ensureAuthorized()
        let engine = AppleSpeechEngine()
        try await engine.start(localeIdentifier: Self.localeIdentifier)
        speechEngine = engine
    }

    /// 显式加载（等价于预加载）。
    func loadModel() async throws {
        try await prepare()
    }

    /// 释放资源：先摘除会话引用再停止，避免 stop 期间新会话被旧值覆盖。
    func unloadModel() async {
        if #available(macOS 26, *) {
            let engine = speechEngine
            speechEngine = nil
            await engine?.stop()
        }
    }

    /// 实时分块：喂入流式会话，返回本次新增文本（增量模式）。
    /// 未产生新内容返回空（AppState 继续累积）。
    /// 授权只在 prepare() 时请求；此处仅检查状态（避免录制中弹窗挂起循环）。
    /// VAD 断句：chunk 尾部连续静音 ≥400ms 视为断句点——立即取当前句返回
    /// （不等 5s 超时），句子快速进入字幕封口 → 触发翻译。
    /// 流式引擎声明：音频去重由 TranscriptionService 水位线统一裁剪，
    /// 本方法收到的 samples 即纯新增采样（absoluteRange 参数忽略）。
    var isStreamingEngine: Bool { true }

    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        try await transcribeChunk(samples: samples, absoluteRange: nil)
    }

    func transcribeChunk(samples: [Float], absoluteRange: Range<Int>?) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }
        guard #available(macOS 26, *) else {
            throw AppleSpeechError.unavailable("Apple Speech 需要 macOS 26+")
        }
        guard AppleSpeechPermission.isSpeechAuthorized else {
            throw AppleSpeechError.notAuthorized
        }
        let preprocessed = Self.preprocess(samples)
        let engine: AppleSpeechEngine
        if let existing = speechEngine, existing.isRunning {
            engine = existing
        } else {
            // 首次 chunk / 旧会话已结束：懒启动新会话（新会话时间轴从空开始）。
            if let stale = speechEngine {
                await stale.stop()
            }
            engine = AppleSpeechEngine()
            try await engine.start(localeIdentifier: Self.localeIdentifier)
            speechEngine = engine
        }
        engine.append(samples: preprocessed)
        // 等待窗口：尾部静音（断句点）→ 1s 取完整句；正常说话 → 0.25s。
        // 不能长等：ASRManager 循环串行等本返回值，长窗口期间不会喂新音频
        // ——流式引擎拿不到音频就不出字（我们等它出字、它等我们喂音），
        // 曾造成每 ~5.5s 才爆发一次 partial、字幕延迟数秒。文本未到时尽快
        // 返回空，让循环继续喂音；下一轮 pass 会先零延迟取走已到的文本。
        let timeout = Self.hasTrailingSilence(preprocessed) ? 1.0 : 0.25
        if let incremental = await engine.waitForTextGrowth(timeout: timeout) {
            incremental.log(provider: "apple", isPartial: true)
            return incremental
        }
        return TranscriptionResult(text: "", segments: [])
    }

    /// 文件转录：临时流式会话喂入全文件 → final 结果。
    /// 音频流式分块解码边喂（AudioLoader.loadSamplesChunked）：长文件
    /// 峰值内存 = 单块 + 引擎缓冲，不再整文件载入。
    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        guard #available(macOS 26, *) else {
            throw AppleSpeechError.unavailable("Apple Speech 需要 macOS 26+")
        }
        try await ensureAuthorized()
        onProgress(0.05)
        // 文件转录接口的 language 参数优先（ISO-639-1 / locale id 均可由
        // supportedLocale(equivalentTo:) 解析）；未指定时用 Apple Speech 设置。
        let requestedLocale = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localeIdentifier = requestedLocale.isEmpty ? Self.localeIdentifier : requestedLocale
        let fileEngine = AppleSpeechEngine()
        // 文件转录会一次性快速喂入全部音频：用 unbounded 缓冲，避免
        // bufferingNewest 在 analyzer 消费不及时时丢弃前面的音频。
        try await fileEngine.start(localeIdentifier: localeIdentifier,
                                   bufferingPolicy: .unbounded,
                                   collectFinalResults: true)
        do {
            // 解码进度映射 0.1–0.6；喂入即解码，无第二次全量持有。
            let chunkSamples = 16000 * 30   // 30s 一块
            try await AudioLoader.loadSamplesChunked(url: fileURL, chunkSamples: chunkSamples) { chunk in
                fileEngine.append(samples: chunk)
                return true   // 不提前终止；取消经任务取消传导（waitForFinalResults 感知）
            }
            fileEngine.finish()
            onProgress(0.7)
            // 超时按音频时长缩放：喂音结束后分析仍需时间，长文件（几十分钟）用
            // 固定 20s 会在分析未完成时提前返回不完整的 final（静默丢句）。
            // 分块模式下总采样数由引擎水位线（时间戳）给出。
            let audioDuration = fileEngine.totalAudioDuration()
            let finalResults = await fileEngine.waitForFinalResults(
                timeout: max(20.0, audioDuration * 2.0))
            // 任务取消（停录后立即退出 / 队列取消）：抛 CancellationError，
            // 不把残缺结果标记为完成转录。
            try Task.checkCancellation()
            guard !finalResults.isEmpty else {
                throw AppleSpeechError.recognitionFailed("文件转录未产生结果")
            }
            await fileEngine.stop()
            let result = Self.makeTranscriptionResult(from: finalResults)
            result.log(provider: "apple")
            onProgress(1)
            return result
        } catch {
            // 失败/取消路径同样必须停掉引擎（有界 stop）：否则 analyzer 与
            // 其内部任务泄漏，speech 连接保持，拖慢甚至卡住退出。
            await fileEngine.stop()
            throw error
        }
    }

    func status() async -> ASRProviderStatus {
        guard Self.isAuthorized else { return .idle }
        if #available(macOS 26, *), let engine = speechEngine, engine.isRunning {
            return .loaded(path: "Apple Speech（\(Self.localeIdentifier)）")
        }
        return .idle
    }

    /// 取消实时会话（录制停止时调用）。
    func cancelPending() {
        if #available(macOS 26, *) {
            let engine = speechEngine
            speechEngine = nil
            Task { await engine?.stop() }
        }
    }

    // MARK: - 文件转录结果聚合

    /// 把 SpeechTranscriber 分次输出的 final 段聚合为统一 TranscriptionResult。
    private static func makeTranscriptionResult(from results: [ASRResult]) -> TranscriptionResult {
        let ordered = results.sorted { $0.timestamp.start < $1.timestamp.start }
        let segments: [TranscriptionSegment] = ordered.compactMap { result in
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptionSegment(start: result.timestamp.start,
                                        end: result.timestamp.end,
                                        text: text)
        }
        let text = segments.map(\.text).joined(separator: " ")
        return TranscriptionResult(text: text,
                                   segments: segments,
                                   detectedLanguage: ordered.first?.language)
    }

    // MARK: - 权限

    private func ensureAuthorized() async throws {
        guard await AppleSpeechPermission.ensureSpeechAuthorized() else {
            throw AppleSpeechError.notAuthorized
        }
    }

    // MARK: - 音频处理

    /// VAD（语音活动检测）：chunk 末尾是否有 ≥400ms 连续静音。
    /// 按 100ms 帧（1600 采样 @16kHz）从尾部向前扫描，连续静音帧数
    /// ≥4（400ms）视为断句点；中途出现语音立即返回 false（不是尾部静音）。
    /// 阈值 0.0015 与 ASRManager 静音阈值一致（干净麦克风底噪 RMS < 0.001）。
    private static func hasTrailingSilence(_ samples: [Float]) -> Bool {
        let frameSamples = 1600          // 100ms @16kHz
        let minSilenceFrames = 4         // 400ms
        guard samples.count >= frameSamples * minSilenceFrames else { return false }
        var silenceFrames = 0
        var index = samples.count - frameSamples
        while index >= 0 {
            let frame = samples[index..<(index + frameSamples)]
            // VAD 联合判定：低能量或高频噪声都算静音（与主循环封口一致）。
            if VAD.isNonSpeech(rms: VAD.rmsEnergy(frame),
                               zcr: VAD.zeroCrossingRate(frame),
                               silenceThreshold: 0.0015) {
                silenceFrames += 1
                if silenceFrames >= minSilenceFrames { return true }
            } else {
                return false             // 中间有语音 → 不是尾部静音
            }
            index -= frameSamples
        }
        return false
    }

    /// 音频预处理：高通去直流 + 噪声底估计 + 小信号增益。
    private static func preprocess(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let alpha: Float = 0.995
        var previousInput: Float = 0
        var previousOutput: Float = 0
        var filtered = [Float](repeating: 0, count: samples.count)

        var sumSquares: Float = 0
        var peak: Float = 0
        for (i, sample) in samples.enumerated() {
            let value = sample - previousInput + alpha * previousOutput
            previousInput = sample
            previousOutput = value
            filtered[i] = value
            sumSquares += value * value
            peak = max(peak, abs(value))
        }
        let rms = (sumSquares / Float(samples.count)).squareRoot()

        var noiseFloor: Float = 0.0012
        let likelyNoiseOnly = peak < 0.02 || rms <= noiseFloor * 1.6
        let smoothing: Float = likelyNoiseOnly ? 0.08 : 0.01
        noiseFloor = min(max(noiseFloor * (1 - smoothing) + rms * smoothing, 0.0005), 0.02)

        let speechFloor = max(0.006, noiseFloor * 4.0)
        let targetPeak: Float = 0.35
        guard peak > speechFloor, rms > max(noiseFloor * 1.8, 0.0015), peak < targetPeak else {
            return filtered
        }
        let gain = min(targetPeak / peak, 3.0)
        return filtered.map { $0 * gain }
    }
}

// MARK: - TranscriptionResult 日志扩展

extension TranscriptionResult {
    /// Provider 输出日志：[ASR Result] provider= text= isPartial=
    func log(provider: String, isPartial: Bool? = nil) {
        print("[ASR Result] provider=\(provider) text=\(text.debugDescription) "
            + "isPartial=\(isPartial ?? false) language=\(detectedLanguage ?? "nil")")
    }
}
