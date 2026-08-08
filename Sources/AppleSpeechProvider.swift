import Foundation
import Speech
import AVFoundation

// MARK: - Apple Speech Provider（AppleSpeechProvider）
//
// macOS 26 新 Speech 架构（v2s 同款），外部 ASRProvider 接口不变：
//
//   AppleSpeechProvider
//        ↓
//   SpeechAnalyzer     音频输入管理 / 分析生命周期 / task 管理
//        ↓
//   SpeechTranscriber  实时语音转文字（partial / final）
//        ↓
//   AnalysisContext    当前语言 / 识别配置（热词）/ 会话状态
//        ↓
//   ASRResult          text / isFinal / confidence / language / timestamp
//
// 生命周期：start() 创建 transcriber + context（会话复用）；
// 每次分析创建 analyzer（模型 modelRetention .whileInUse 复用）；
// stop() 释放会话。macOS <26 回退 SFSpeechRecognizer（legacy）。
//
// 错误分类（权限 / 语言资源 / 初始化 / 识别）抛给上层 catch——
// 不影响其他 ASR Provider。语言资源经 Speech 框架能力检测
// （SpeechTranscriber.installedLocales + AssetInventory 自动下载）。
//
// 权限：需要在 Info.plist 声明 NSSpeechRecognitionUsageDescription。

final class AppleSpeechProvider: @unchecked Sendable, ASRProvider {
    // MARK: - 错误分类

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

    var engine: ASRProviderEngine { .apple }

    // MARK: - 静态配置 / 能力

    /// 识别语言（UserDefaults "appleSpeechLocale"，默认 zh-CN）。
    static var localeIdentifier: String {
        let raw = UserDefaults.standard.string(forKey: "appleSpeechLocale") ?? ""
        return raw.isEmpty ? "zh-CN" : raw
    }

    /// 是否启用 on-device（设备本地识别，无网络依赖；默认开启）。
    static var prefersOnDevice: Bool {
        UserDefaults.standard.object(forKey: "appleSpeechOnDevice") == nil
            ? true : UserDefaults.standard.bool(forKey: "appleSpeechOnDevice")
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    // MARK: - 会话状态（start/stop 生命周期）

    /// macOS 26 会话（SpeechTranscriber + AnalysisContext 会话级复用）。
    @available(macOS 26, *)
    private struct SpeechSession {
        let transcriber: SpeechTranscriber
        let locale: Locale
        let context: AnalysisContext
        /// 识别最优音频格式（bestAvailableAudioFormat 解析一次）。
        let format: AVAudioFormat
    }

    private let stateLock = NSLock()
    private var activeTask: SFSpeechRecognitionTask?      // legacy 在途任务
    private var cachedRecognizer: SFSpeechRecognizer?     // legacy 识别器
    private var sessionStorage: Any?                       // SpeechSession（#available 内访问）
    private var modernUsable = true
    private var modernFailures = 0
    /// 当前语言是否已安装（缓存 60 秒；on-device 判定用）。
    private var localeInstalledCache: (date: Date, installed: Bool)?

    @available(macOS 26, *)
    private var session: SpeechSession? {
        get { sessionStorage as? SpeechSession }
        set { sessionStorage = newValue }
    }

    // MARK: - ASRProvider

    /// 预加载：请求授权 + 创建会话（SpeechAnalyzer/SpeechTranscriber/AnalysisContext）
    /// + 语言包自动下载（失败不阻断）。
    func prepare() async throws {
        try await ensureAuthorized()
        if #available(macOS 26, *) {
            try await startSession()
        }
        await ensureLanguageAssetInstalled()
    }

    /// 显式加载（等价于校验可用性 + 会话创建）。
    func loadModel() async throws {
        try await ensureAuthorized()
        if #available(macOS 26, *) {
            try await startSession()
        }
        await ensureLanguageAssetInstalled()
    }

    /// 释放资源：停止会话（释放 analysis task）。
    func unloadModel() async {
        stopSession()
        stateLock.withLock {
            activeTask?.cancel()
            activeTask = nil
            cachedRecognizer = nil
        }
    }

    /// 实时分块转录：预处理 → 新架构分析（macOS 26）或 legacy 回退。
    /// 时间戳相对当前分块起点（与本地引擎约定一致）。
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }
        // v2s 预处理：高通去直流 + 噪声底估计 + 小信号增益（只影响本引擎）。
        let preprocessed = Self.preprocess(samples)
        try await ensureAuthorized()
        if #available(macOS 26, *) {
            if modernUsable, let session {
                do {
                    let result = try await analyzeChunk(preprocessed, session: session)
                    result.log(provider: "apple")
                    return Self.makeTranscriptionResult(result)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    modernFailures += 1
                    AppLogger.shared.log(.asr, "Apple Speech: analyze failed, fallback to legacy — \(error.localizedDescription)")
                }
            }
        }
        return try await transcribeChunkLegacy(preprocessed)
    }

    /// 文件转录：解码 → 16kHz WAV → 新架构文件分析或 legacy 回退。
    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        try await ensureAuthorized()
        let samples = try await AudioLoader.loadSamples(url: fileURL)
        onProgress(0.3)
        let wav = WAVEncoder.encodePCM16(samples: samples)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-speech-\(UUID().uuidString).wav")
        try wav.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        if #available(macOS 26, *) {
            if modernUsable, let session {
                do {
                    let result = try await analyzeFile(wavURL: tmp, session: session)
                    onProgress(1)
                    return Self.makeTranscriptionResult(result)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    modernFailures += 1
                    AppLogger.shared.log(.asr, "Apple Speech: file analyze failed, fallback to legacy — \(error.localizedDescription)")
                }
            }
        }
        let result = try await transcribeFileLegacy(wavURL: tmp)
        onProgress(1)
        return result
    }

    func status() async -> ASRProviderStatus {
        guard Self.isAuthorized else { return .idle }
        if #available(macOS 26, *) {
            if session != nil {
                return .loaded(path: "Apple Speech（\(Self.localeIdentifier)）")
            }
        }
        return .idle
    }

    // MARK: - 生命周期（start / stop）

    /// start()：创建 SpeechTranscriber + AnalysisContext + 解析音频格式。
    @available(macOS 26, *)
    private func startSession() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechError.unavailable("SpeechTranscriber 不可用")
        }
        let locale = Locale(identifier: Self.localeIdentifier)
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.localeUnsupported(Self.localeIdentifier)
        }
        // SpeechTranscriber：实时语音转文字（partial/final）。
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        // AnalysisContext：当前语言 / 识别配置（热词）/ 会话状态。
        let context = AnalysisContext()
        let keywords = ASRPromptManager.shared.contextualKeywords
        if !keywords.isEmpty {
            context.contextualStrings[.general] = keywords
        }
        // 识别最优音频格式（SpeechAnalyzer 能力检测）。
        let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 16000, channels: 1, interleaved: false)!
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: natural) ?? natural

        stateLock.withLock {
            session = SpeechSession(transcriber: transcriber, locale: resolved,
                                    context: context, format: format)
            modernUsable = true
            modernFailures = 0
        }
        AppLogger.shared.log(.asr, "Apple Speech: session started (\(resolved.identifier))")
    }

    /// stop()：释放会话（analysis task 随引用释放；模型由 whileInUse 保留策略管理）。
    private func stopSession() {
        stateLock.withLock {
            sessionStorage = nil
            localeInstalledCache = nil
            modernUsable = true
            modernFailures = 0
        }
        AppLogger.shared.log(.asr, "Apple Speech: session stopped")
    }

    // MARK: - SpeechAnalyzer 分析（音频输入 / 生命周期 / task）

    /// 分块分析：创建 analyzer（绑定会话 transcriber + context）→ 输入流 → 结果。
    @available(macOS 26, *)
    private func analyzeChunk(_ samples: [Float], session: SpeechSession) async throws -> ASRResult {
        let analyzer = try await makeAnalyzer(session: session)
        let source = makePCMBuffer(samples)
        let inputBuffer = convertBuffer(source, to: session.format) ?? source
        let input = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(4)) { continuation in
            continuation.yield(AnalyzerInput(buffer: inputBuffer, bufferStartTime: .zero))
            continuation.finish()
        }
        return try await runAnalysis(session: session, analyzer: analyzer, input: input)
    }

    /// 文件分析：analyzer 直接消费 WAV 文件（finishAfterFile 自动结束）。
    @available(macOS 26, *)
    private func analyzeFile(wavURL: URL, session: SpeechSession) async throws -> ASRResult {
        let analyzer = try await makeAnalyzer(session: session)
        let file = try AVAudioFile(forReading: wavURL)
        return try await runAnalysis(session: session, analyzer: analyzer, input: nil, audioFile: file)
    }

    /// 创建 analyzer（每次分析独立实例；模型经 modelRetention .whileInUse 复用）。
    @available(macOS 26, *)
    private func makeAnalyzer(session: SpeechSession) async throws -> SpeechAnalyzer {
        let analyzer = SpeechAnalyzer(
            modules: [session.transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
        do {
            try await analyzer.setContext(session.context)
            try await analyzer.prepareToAnalyze(in: session.format)
            return analyzer
        } catch {
            throw AppleSpeechError.initializationFailed(error.localizedDescription)
        }
    }

    /// 启动分析并消费 transcriber.results，等待 final；超时返回空结果。
    @available(macOS 26, *)
    private func runAnalysis(session: SpeechSession,
                             analyzer: SpeechAnalyzer,
                             input: AsyncStream<AnalyzerInput>?,
                             audioFile: AVAudioFile? = nil) async throws -> ASRResult {
        try await withThrowingTaskGroup(of: ASRResult?.self) { group in
            group.addTask {
                var latest: SpeechTranscriber.Result?
                let consume = Task {
                    do {
                        // partial 立即返回（不等待 final）：实时字幕不延迟。
                        for try await r in session.transcriber.results {
                            latest = r
                            break
                        }
                    } catch is CancellationError {
                    } catch {}
                }
                do {
                    if let audioFile {
                        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
                    } else if let input {
                        try await analyzer.start(inputSequence: input)
                    }
                    _ = await consume.result
                } catch is CancellationError {
                    return nil
                } catch {
                    throw error
                }
                guard let latest else { return nil }
                return Self.makeASRResult(latest, locale: Self.localeIdentifier)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil  // 超时：返回空结果（字幕不挂死）
            }
            let result = try await group.next()!
            group.cancelAll()
            return result ?? ASRResult(text: "", isFinal: true,
                                       language: Self.localeIdentifier.components(separatedBy: "-").first,
                                       confidence: nil, timestamp: (0, nil))
        }
    }

    /// SpeechTranscriber.Result → ASRResult（text/isFinal/confidence/language/timestamp）。
    @available(macOS 26, *)
    private static func makeASRResult(_ result: SpeechTranscriber.Result,
                                      locale: String) -> ASRResult {
        let text = String(result.text.characters)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 置信度：逐 run transcriptionConfidence 平均（缺失回退 0.82，v2s 同款）。
        var total: Double = 0
        var count = 0
        for run in result.text.runs {
            if let confidence = run.transcriptionConfidence {
                total += confidence
                count += 1
            }
        }
        let confidence = count > 0 ? Float(total / Double(count)) : nil
        return ASRResult(
            text: text,
            isFinal: result.isFinal,
            language: locale.components(separatedBy: "-").first,
            confidence: confidence,
            timestamp: (result.range.start.seconds, result.range.end.seconds)
        )
    }

    /// ASRResult → TranscriptionResult（单段，时间戳相对 chunk 起点）。
    private static func makeTranscriptionResult(_ result: ASRResult) -> TranscriptionResult {
        result.toTranscriptionResult()
    }

    // MARK: - 语言资源（新框架能力检测）

    /// 当前语言是否已安装（缓存 60 秒）。
    private func currentLocaleIsInstalled() async -> Bool {
        if let cache = stateLock.withLock({ localeInstalledCache }),
           Date().timeIntervalSince(cache.date) < 60 {
            return cache.installed
        }
        let locales = await AppleSpeechLanguageManager.shared.installedLanguages()
        let installed = locales.contains { $0.identifier == Self.localeIdentifier }
        stateLock.withLock { localeInstalledCache = (Date(), installed) }
        return installed
    }

    /// 语言包自动下载（macOS 26+ AssetInventory；失败不阻断）。
    private func ensureLanguageAssetInstalled() async {
        guard #available(macOS 26, *) else { return }
        guard await currentLocaleIsInstalled() == false else { return }
        let locale = Locale(identifier: Self.localeIdentifier)
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        let transcriber = SpeechTranscriber(
            locale: resolved, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        do {
            if let installer = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                AppLogger.shared.log(.asr, "Apple Speech: downloading language asset \(resolved.identifier)")
                try await installer.downloadAndInstall()
                stateLock.withLock { localeInstalledCache = nil }
                AppLogger.shared.log(.asr, "Apple Speech: language asset installed \(resolved.identifier)")
            }
        } catch {
            AppLogger.shared.log(.asr, "Apple Speech: language asset download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 权限

    private func ensureAuthorized() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw AppleSpeechError.notAuthorized }
        case .denied, .restricted:
            throw AppleSpeechError.notAuthorized
        @unknown default:
            throw AppleSpeechError.notAuthorized
        }
    }

    // MARK: - Legacy 回退（macOS <26）

    /// legacy 分块：SFSpeechRecognizer 每 chunk 独立任务。
    private func transcribeChunkLegacy(_ samples: [Float]) async throws -> TranscriptionResult {
        let recognizer = try makeLegacyRecognizer()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = ASRPromptManager.shared.contextualKeywords
        request.requiresOnDeviceRecognition = await shouldUseOnDevice(recognizer)
        request.append(makeRecognizerBuffer(samples, nativeFormat: request.nativeAudioFormat))
        request.endAudio()
        return try await runLegacyTask(recognizer, request: request)
    }

    /// legacy 文件：SFSpeechURLRecognitionRequest。
    private func transcribeFileLegacy(wavURL: URL) async throws -> TranscriptionResult {
        let recognizer = try makeLegacyRecognizer()
        let request = SFSpeechURLRecognitionRequest(url: wavURL)
        request.requiresOnDeviceRecognition = await shouldUseOnDevice(recognizer)
        return try await runLegacyTask(recognizer, request: request)
    }

    private func makeLegacyRecognizer() throws -> SFSpeechRecognizer {
        let cached = stateLock.withLock({ cachedRecognizer })
        if let cached {
            guard cached.isAvailable else {
                throw AppleSpeechError.unavailable("语音识别器不可用（语言资源未就绪：\(Self.localeIdentifier)）")
            }
            return cached
        }
        let preferred = Locale(identifier: Self.localeIdentifier)
        let fallback = Locale(identifier: "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: preferred)
                ?? SFSpeechRecognizer(locale: fallback) else {
            throw AppleSpeechError.unavailable("无法创建语音识别器")
        }
        guard recognizer.isAvailable else {
            throw AppleSpeechError.unavailable("语音识别器不可用（语言资源未就绪：\(Self.localeIdentifier)）")
        }
        stateLock.withLock { cachedRecognizer = recognizer }
        return recognizer
    }

    private func shouldUseOnDevice(_ recognizer: SFSpeechRecognizer) async -> Bool {
        guard Self.prefersOnDevice, recognizer.supportsOnDeviceRecognition else { return false }
        return await currentLocaleIsInstalled()
    }

    /// legacy 任务：partial 收集 + 15s 超时兜底 + 取消静默。
    private func runLegacyTask(_ recognizer: SFSpeechRecognizer,
                               request: SFSpeechRecognitionRequest) async throws -> TranscriptionResult {
        try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            group.addTask {
                try await self.awaitLegacyRecognition(recognizer, request: request)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                self.stateLock.withLock {
                    self.activeTask?.cancel()
                    self.activeTask = nil
                }
                return TranscriptionResult(text: "", segments: [])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func awaitLegacyRecognition(_ recognizer: SFSpeechRecognizer,
                                        request: SFSpeechRecognitionRequest) async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult, Error>) in
            var latestPartial = ""
            var resumed = false
            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    self.stateLock.withLock { self.activeTask = nil }
                    guard !resumed else { return }
                    resumed = true
                    let nsError = error as NSError
                    let isCancellation = (nsError.domain == "kAFAssistantErrorDomain"
                        && (nsError.code == 216 || nsError.code == 301))
                        || (error as? URLError)?.code == .cancelled
                    if isCancellation {
                        continuation.resume(returning: Self.makeLegacyResult(
                            text: latestPartial, locale: Self.localeIdentifier))
                        return
                    }
                    if !latestPartial.isEmpty {
                        continuation.resume(returning: Self.makeLegacyResult(
                            text: latestPartial, locale: Self.localeIdentifier))
                    } else {
                        continuation.resume(throwing: AppleSpeechError.recognitionFailed(
                            error.localizedDescription))
                    }
                    return
                }
                guard let result else { return }
                latestPartial = result.bestTranscription.formattedString
                guard result.isFinal else { return }
                self.stateLock.withLock { self.activeTask = nil }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: Self.makeLegacyResult(
                    result: result, locale: Self.localeIdentifier))
            }
            stateLock.withLock { self.activeTask = task }
        }
    }

    private static func makeLegacyResult(result: SFSpeechRecognitionResult,
                                         locale: String) -> TranscriptionResult {
        let fullText = result.bestTranscription.formattedString
        var segments: [TranscriptionSegment] = []
        for seg in result.bestTranscription.segments {
            let text = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(TranscriptionSegment(
                start: seg.timestamp,
                end: seg.timestamp + seg.duration,
                text: text
            ))
        }
        if segments.isEmpty, !fullText.isEmpty {
            segments = [TranscriptionSegment(start: 0, end: nil, text: fullText)]
        }
        return TranscriptionResult(
            text: fullText,
            segments: segments,
            detectedLanguage: locale.components(separatedBy: "-").first
        )
    }

    private static func makeLegacyResult(text: String, locale: String) -> TranscriptionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: trimmed,
            segments: trimmed.isEmpty
                ? []
                : [TranscriptionSegment(start: 0, end: nil, text: trimmed)],
            detectedLanguage: locale.components(separatedBy: "-").first
        )
    }

    // MARK: - 音频处理

    /// 按请求原生格式转换音频（legacy；v2s 模式）。
    private func makeRecognizerBuffer(_ samples: [Float],
                                      nativeFormat: AVAudioFormat) -> AVAudioPCMBuffer {
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false)!
        let sourceBuffer = makePCMBuffer(samples)
        if sourceFormat.isEqual(nativeFormat) { return sourceBuffer }
        return convertBuffer(sourceBuffer, to: nativeFormat) ?? sourceBuffer
    }

    /// 通用格式转换（AVAudioConverter）。
    private func convertBuffer(_ source: AVAudioPCMBuffer,
                               to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: source.format, to: format),
              let out = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(
                      Double(source.frameLength) * format.sampleRate / source.format.sampleRate + 1)
              ) else { return nil }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        return out.frameLength > 0 ? out : nil
    }

    /// [Float] 16kHz mono → AVAudioPCMBuffer（float32）。
    private func makePCMBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    /// v2s 音频预处理：一阶高通去直流（α=0.995）+ 噪声底估计 + 小信号增益
    /// （目标峰值 0.35，最多 3×；静音/正常/大声不动）。
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

        // 噪声底估计（平滑；clamp 0.0005~0.02）。
        var noiseFloor: Float = 0.0012
        let likelyNoiseOnly = peak < 0.02 || rms <= noiseFloor * 1.6
        let smoothing: Float = likelyNoiseOnly ? 0.08 : 0.01
        noiseFloor = min(max(noiseFloor * (1 - smoothing) + rms * smoothing, 0.0005), 0.02)

        // 增益补偿：只提升"过静语音"。
        let speechFloor = max(0.006, noiseFloor * 4.0)
        let targetPeak: Float = 0.35
        guard peak > speechFloor, rms > max(noiseFloor * 1.8, 0.0015), peak < targetPeak else {
            return filtered
        }
        let gain = min(targetPeak / peak, 3.0)
        return filtered.map { $0 * gain }
    }
}
