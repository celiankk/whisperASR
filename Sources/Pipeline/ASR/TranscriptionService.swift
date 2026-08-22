import Foundation

/// 引擎门面（1.4 渐进式重构第一步）：解析当前模型 → 对应 ASRProvider → 委托转录。
///
/// 1.4 中本类直接调用 CWhisper / NemotronEngine / Qwen3ASRBackend；
/// 重构后仅面向 ASRProvider 协议调度，具体推理由各自适配层完成：
///
///   TranscriptionService
///         ↓
///      ASRProvider
///         ↓
///   WhisperProvider 包装 CWhisper（whisper.cpp）
///   NemotronProvider 包装 NemotronEngine（FluidAudio / Core ML）
///   QwenProvider     包装 Qwen3ASRBackend（transcribe.cpp / ggml + Metal）
///
/// 对外 API（transcribe / transcribeChunk / preloadLiveModel /
/// unloadLiveModel / shutdown / 静态查询）与输入输出数据结构保持不变。
final class TranscriptionService: @unchecked Sendable {
    private let whisperProvider = WhisperProvider()
    private let nemotronProvider = NemotronProvider()
    private let qwenProvider = QwenProvider()
    /// 在线 OpenAI 兼容 Whisper API（无本地模型，需在设置中启用并配置）。
    private let onlineProvider = OnlineASRProvider()
    /// Apple Speech（macOS 26 原生 SpeechAnalyzer / SpeechTranscriber 引擎）。
    private let appleProvider = AppleSpeechManager.shared
    /// FunASR（SenseVoice / Paraformer 系）。
    private let funasrProvider = FunASRProvider()

    /// True while a live session runs on the Nemotron engine — blocks the
    /// "unload nemotron when file-transcribing with whisper" eviction below.
    private let liveStateLock = NSLock()
    private var liveNemotronActive = false
    /// 统一音频分片聚合器（按「音频分片模式」+ 引擎类型决定是否启用）。
    private let chunkManager = ChunkManager()
    /// 流式引擎喂音水位线（tail 重转录重叠去重；见 ASRProvider 声明）。
    /// 生命周期：unloadLiveModel 清零；实时引擎切换清零（会话语义变化）。
    private var streamingWaterline = StreamingFeedWaterline()
    /// 最近一次经水位线裁剪的流式引擎标识（切换即重置水位线）。
    private var streamingWaterlineEngine: ASRProviderEngine? = nil
    private let waterlineLock = NSLock()

    /// Which engine the currently selected model runs on.
    private enum ResolvedEngine {
        case whisper(path: String)
        case nemotron(directory: String)
        case qwen3asr(path: String)
        case online
        case apple
        case funasr
    }

    /// Engine resolution: the user's ASR Engine selection takes precedence
    /// (switching takes effect immediately, no restart). `auto` keeps the
    /// 1.4 path-based detection.
    private func resolveEngine() -> ResolvedEngine {
        switch ASREngineSelection.current {
        case .online:
            // 开关未启用时回落自动判定（本地模型）。
            guard OnlineASRConfig.isEnabled else {
                return Self.engine(forPath: ModelPathResolver.resolveModelPath())
            }
            return .online
        case .whisper:
            return .whisper(path: ModelPathResolver.resolveModelPath())
        case .qwen:
            return .qwen3asr(path: ModelPathResolver.resolveModelPath())
        case .nemotron:
            return .nemotron(directory: ModelPathResolver.resolveModelPath())
        case .apple:
            return .apple
        case .funasr:
            return .funasr
        case .auto:
            return Self.engine(forPath: ModelPathResolver.resolveModelPath())
        }
    }

    /// Engine for the live-transcription model selection. The user's ASR
    /// Engine selection takes precedence; otherwise the live model path
    /// (`liveModelFile`, falling back to the main model) decides, matching 1.4.
    private func resolveLiveEngine() -> ResolvedEngine {
        switch ASREngineSelection.current {
        case .online:
            // 开关未启用时回落自动判定（本地模型）。
            guard OnlineASRConfig.isEnabled else {
                return Self.engine(forPath: ModelPathResolver.resolveLiveModelPath())
            }
            return .online
        case .whisper:
            return .whisper(path: ModelPathResolver.resolveLiveModelPath())
        case .qwen:
            return .qwen3asr(path: ModelPathResolver.resolveLiveModelPath())
        case .nemotron:
            return .nemotron(directory: ModelPathResolver.resolveLiveModelPath())
        case .apple:
            return .apple
        case .funasr:
            return .funasr
        case .auto:
            return Self.engine(forPath: ModelPathResolver.resolveLiveModelPath())
        }
    }

    private static func engine(forPath path: String) -> ResolvedEngine {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            // 目录模型：先按 catalog 元数据判引擎（FunASR 目录 → .funasr，
            // 否则回落 Nemotron——曾把 SenseVoice 目录误判为 Nemotron，
            // 报 metadata.json not found）。
            let dirName = (path as NSString).lastPathComponent
            if let catalogModel = ModelCatalog.model(fileName: dirName),
               catalogModel.engine == .funasr {
                return .funasr
            }
            return .nemotron(directory: path)
        }
        // Qwen3-ASR 是单文件 GGUF：按目录中的模型名识别，避免被误当成 whisper 加载。
        let fileName = (path as NSString).lastPathComponent
        if let catalogModel = ModelCatalog.model(fileName: fileName) {
            if catalogModel.engine == .qwen3asr { return .qwen3asr(path: path) }
            if catalogModel.engine == .funasr { return .funasr }
        }
        // 自定义路径/非标准文件名：读取 GGUF 头部 general.architecture 判定。
        if let arch = GGUFInspector.architecture(atPath: path)?.lowercased(),
           arch.contains("qwen3_asr") || arch.contains("qwen3-asr") {
            return .qwen3asr(path: path)
        }
        return .whisper(path: path)
    }

    func shutdown() {
        unloadLiveModel()
        Task { await whisperProvider.unloadModel() }
        Task { await nemotronProvider.unloadModel() }
        Task { await qwenProvider.unloadModel() }
        Task { await onlineProvider.unloadModel() }
        Task { await appleProvider.unloadModel() }
    }

    /// Free the live session's resources when recording ends: the dedicated
    /// live whisper context (if any), and the Nemotron engine when only the
    /// live selection was using it. Online mode: cancel in-flight requests
    /// and drop the pending audio queue.
    func unloadLiveModel() {
        let wasNemotron = liveStateLock.withLock {
            let was = liveNemotronActive
            liveNemotronActive = false
            return was
        }

        whisperProvider.unloadLiveModel()
        if wasNemotron, case .whisper = resolveEngine() {
            Task { await nemotronProvider.unloadModel() }
        }
        Task { await qwenProvider.unloadModel() }
        onlineProvider.cancelPending()
        Task { await appleProvider.unloadModel() }
        chunkManager.clear()  // 丢弃未发送的聚合残留
        waterlineLock.withLock {
            streamingWaterline.reset()
            streamingWaterlineEngine = nil
        }
    }

    /// Transcribe (or translate-to-English, when `translate` is true) an audio file.
    /// `language` is an optional ISO-639-1 code; nil/empty means auto-detect.
    /// 显式传入优先；未传时应用设置页「识别语言」的配置（仅对支持手动
    /// 指定的引擎生效——whisper / nemotron / 在线；Apple 用自己的语言包
    /// 设置、Qwen 自动检测，均不受配置影响）。
    func transcribe(fileURL: URL,
                    language: String? = nil,
                    translate: Bool = false,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        let configuredLanguage = ConfigurationManager.shared.asr.effectiveASRLanguage
        let effectiveLanguage = (language?.isEmpty == false) ? language : configuredLanguage
        switch resolveEngine() {
        case .nemotron:
            guard !translate else {
                throw TranscriptionError.processFailed(
                    "Translation to English is not supported by the Nemotron model. Select a Whisper model instead."
                )
            }
            // Free the main whisper ctx (a live session's context stays).
            Task { await whisperProvider.unloadModel() }
            return try await nemotronProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .qwen3asr:
            return try await qwenProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .whisper:
            let keepNemotron = liveStateLock.withLock { liveNemotronActive }  // live session is using it
            if !keepNemotron {
                Task { await nemotronProvider.unloadModel() }
            }
            return try await whisperProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .online:
            guard !translate else {
                throw TranscriptionError.processFailed(
                    "Translation to English is not supported by the Online API. Select a Whisper model instead."
                )
            }
            return try await onlineProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .apple:
            guard !translate else {
                throw TranscriptionError.processFailed(
                    "Translation to English is not supported by Apple Speech. Select a Whisper model instead."
                )
            }
            // Apple：language 参数原样透传（不套用「识别语言」配置——
            // Apple 有自己的语言包选择器，空值回落 appleSpeechLocale）。
            return try await appleProvider.transcribeFile(
                fileURL: fileURL, language: language, translate: translate, onProgress: onProgress
            )
        case .funasr:
            return try await funasrProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        }
    }

    // MARK: - Chunk Transcription (Live/Streaming)

    /// Transcribe raw 16kHz mono PCM Float32 samples directly (used for live transcription during recording).
    /// Uses the live model selection (falling back to the main model) and runs on a background queue.
    ///
    /// 音频分片（Chunk Manager）：
    /// - 按「音频分片模式」+ 当前引擎类型决定是否聚合：
    ///   关闭 → 直接发送 Provider（原实时流程）；
    ///   仅本地 → 本地引擎聚合、Online 跳过；仅在线 → Online 聚合、本地跳过；
    /// - 聚合未达标（时长 / 等待）时返回空结果，上层循环继续累积；
    /// - `absoluteRange` 是 chunk 在录制时间轴上的绝对采样区间，供流式引擎
    ///   （Apple Speech）做去重水位线；聚合路径会打乱位置 → 透传 nil。
    func transcribeChunk(samples: [Float],
                         absoluteRange: Range<Int>? = nil) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }

        let engine = resolveLiveEngine()
        if shouldChunk(engine: engine) {
            chunkManager.append(samples)
            guard chunkManager.isReadyToSend() else {
                return TranscriptionResult(text: "", segments: [])
            }
            let chunk = chunkManager.takeAll()
            return try await dispatchChunk(chunk, engine: engine, absoluteRange: nil)
        }

        // 流式引擎：tail 重转录的重叠区间按绝对水位线裁剪（provider 只收
        // 纯新增采样，见 ASRProvider.isStreamingEngine）。无状态引擎直通。
        let liveProvider = provider(for: engine)
        let samplesToFeed: [Float]
        if liveProvider.isStreamingEngine {
            samplesToFeed = waterlineLock.withLock { () -> [Float] in
                if streamingWaterlineEngine != liveProvider.engine {
                    streamingWaterline.reset()
                    streamingWaterlineEngine = liveProvider.engine
                }
                guard let range = absoluteRange else {
                    streamingWaterline.markUntrackedFeed()
                    return samples
                }
                guard let start = streamingWaterline.unfedStart(in: range) else {
                    return []
                }
                return Array(samples[start...])
            }
            if samplesToFeed.isEmpty {
                return TranscriptionResult(text: "", segments: [])
            }
        } else {
            samplesToFeed = samples
        }
        return try await dispatchChunk(samplesToFeed, engine: engine, absoluteRange: absoluteRange)
    }

    /// 引擎 → provider（水位线路径用；与 dispatchChunk 同一分发表）。
    private func provider(for engine: ResolvedEngine) -> ASRProvider {
        switch engine {
        case .nemotron: return nemotronProvider
        case .qwen3asr: return qwenProvider
        case .whisper: return whisperProvider
        case .online: return onlineProvider
        case .apple: return appleProvider
        case .funasr: return funasrProvider
        }
    }

    /// 把切片（或原样样本）发送到对应引擎的 Provider。
    private func dispatchChunk(_ samples: [Float],
                               engine: ResolvedEngine,
                               absoluteRange: Range<Int>?) async throws -> TranscriptionResult {
        switch engine {
        case .nemotron:
            return try await nemotronProvider.transcribeChunk(samples: samples, absoluteRange: absoluteRange)
        case .qwen3asr:
            return try await qwenProvider.transcribeChunk(samples: samples, absoluteRange: absoluteRange)
        case .whisper:
            return try await whisperProvider.transcribeChunk(samples: samples, absoluteRange: absoluteRange)
        case .online:
            return try await onlineProvider.transcribeChunk(samples: samples, absoluteRange: absoluteRange)
        case .apple:
            return try await appleProvider.transcribeChunk(samples: samples, absoluteRange: absoluteRange)
        case .funasr:
            return try await funasrProvider.transcribeChunk(samples: samples, absoluteRange: absoluteRange)
        }
    }

    /// 音频分片判定：按「音频分片模式」+ 引擎类型。
    /// - Online API 恒不参与（句子模式由 Provider 内 OnlineASRBuffer 负责，
    ///   避免双重聚合）；
    /// - Apple Speech 不参与分片（系统流式识别按块直接发送）。
    private func shouldChunk(engine: ResolvedEngine) -> Bool {
        switch AudioChunkingMode.current {
        case .off:
            return false
        case .localOnly:
            switch engine {
            case .whisper, .nemotron, .qwen3asr: return true
            case .online, .apple, .funasr: return false
            }
        case .onlineOnly:
            switch engine {
            case .online: return false
            case .whisper, .nemotron, .qwen3asr, .apple, .funasr: return false
            }
        }
    }

    /// 实时引擎是否输出「纯增量」分块结果（Apple 流式引擎：音频持续喂入同一
    /// 会话，每次只返回新增文本）。这类引擎没有 tail 重转录的音频 overlap，
    /// 强制封口后不需要对首字符做 overlap 裁剪。
    var liveEngineStreamsIncrementally: Bool {
        if case .apple = resolveLiveEngine() { return true }
        return false
    }

    /// Ensure the live-transcription model is loaded (pre-loading at recording
    /// start, to avoid model loading latency on the first chunk).
    func preloadLiveModel() async throws {
        switch resolveLiveEngine() {
        case .whisper:
            liveStateLock.withLock { liveNemotronActive = false }
            try await whisperProvider.prepare()
        case .nemotron:
            liveStateLock.withLock { liveNemotronActive = true }
            try await nemotronProvider.prepare()
        case .qwen3asr:
            try await qwenProvider.prepare()
        case .funasr:
            try await funasrProvider.prepare()
        case .online:
            // 在线模式：校验配置（失败时由调用方提示，不影响本地引擎）。
            try await onlineProvider.prepare()
        case .apple:
            // Apple Speech：请求授权并启动流式会话（语言资源缺失自动下载）。
            try await appleProvider.prepare()
        }
    }

    // MARK: - Static Queries（UI / API 层继续使用，行为不变）

    /// 当前识别配置对「手动指定识别语言」的支持（设置页 UI 用）。
    enum ASRLanguageSupport {
        /// 可选（whisper / nemotron / 在线）：显示语言选择器。
        case selectable
        /// 自动检测、不可指定（Qwen3-ASR），附说明文字。
        case autoOnly(String)
        /// Apple：按 Apple Speech 语言包设置。
        case appleLocale
    }

    /// 按当前引擎选择（本地按所选模型解析引擎）判定语言选择支持。
    static var languageSupport: ASRLanguageSupport {
        let qwenAuto = ASRLanguageSupport.autoOnly(
            "Qwen3-ASR 自动语种检测（30 种语言 + 22 种中文方言），不支持手动指定。")
        switch ASREngineSelection.current {
        case .apple:
            return .appleLocale
        case .online:
            return .selectable
        case .qwen:
            return qwenAuto
        case .funasr:
            return .selectable
        case .auto, .whisper, .nemotron:
            if case .qwen3asr = engine(forPath: ModelPathResolver.resolveModelPath()) {
                return qwenAuto
            }
            return .selectable
        }
    }

    static var appSupportModelPath: String {
        ModelPathResolver.appSupportModelPath
    }

    /// Check whether a usable model file exists at any known location.
    static func modelExists() -> Bool {
        if let files = try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path),
           // whisper 模型是 .bin，Qwen3-ASR 等 GGUF 模型是 .gguf。
           files.contains(where: { $0.hasSuffix(".bin") || $0.hasSuffix(".gguf") }) {
            return true
        }
        if ModelCatalog.all.contains(where: { $0.engine == .nemotron && ModelCatalog.isComplete($0) }) {
            return true
        }
        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return true
        }
        if FileManager.default.fileExists(atPath: appSupportModelPath) {
            return true
        }
        let thisFile = #filePath
        let sourcesDir = (thisFile as NSString).deletingLastPathComponent
        let projectRoot = (sourcesDir as NSString).deletingLastPathComponent
        let projectPath = (projectRoot as NSString).appendingPathComponent("Models/ggml-model.bin")
        return FileManager.default.fileExists(atPath: projectPath)
    }

    /// Returns all languages supported by the loaded whisper.cpp library.
    static func availableLanguages() -> [(code: String, name: String)] {
        WhisperProvider.availableLanguages()
    }

#if DEBUG
    /// 调试：打印指定路径的 GGUF 架构与解析出的引擎。
    static func debugEngineDescription(forPath path: String) -> String {
        let arch = GGUFInspector.architecture(atPath: path) ?? "unknown"
        switch engine(forPath: path) {
        case .whisper: return "arch=\(arch) engine=whisper"
        case .nemotron: return "arch=\(arch) engine=nemotron"
        case .qwen3asr: return "arch=\(arch) engine=qwen3asr"
        case .online: return "arch=\(arch) engine=online"
        case .apple: return "arch=\(arch) engine=apple"
        case .funasr: return "arch=\(arch) engine=funasr"
        }
    }
#endif
}
