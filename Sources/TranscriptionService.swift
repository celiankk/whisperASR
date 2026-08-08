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

    /// True while a live session runs on the Nemotron engine — blocks the
    /// "unload nemotron when file-transcribing with whisper" eviction below.
    private let liveStateLock = NSLock()
    private var liveNemotronActive = false

    /// Which engine the currently selected model runs on.
    private enum ResolvedEngine {
        case whisper(path: String)
        case nemotron(directory: String)
        case qwen3asr(path: String)
    }

    /// Whisper models are single files; Nemotron bundles are directories.
    private func resolveEngine() -> ResolvedEngine {
        Self.engine(forPath: ModelPathResolver.resolveModelPath())
    }

    /// Engine for the live-transcription model selection.
    private func resolveLiveEngine() -> ResolvedEngine {
        Self.engine(forPath: ModelPathResolver.resolveLiveModelPath())
    }

    private static func engine(forPath path: String) -> ResolvedEngine {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .nemotron(directory: path)
        }
        // Qwen3-ASR 是单文件 GGUF：按目录中的模型名识别，避免被误当成 whisper 加载。
        let fileName = (path as NSString).lastPathComponent
        if let catalogModel = ModelCatalog.model(fileName: fileName),
           catalogModel.engine == .qwen3asr {
            return .qwen3asr(path: path)
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
    }

    /// Free the live session's resources when recording ends: the dedicated
    /// live whisper context (if any), and the Nemotron engine when only the
    /// live selection was using it.
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
    }

    /// Transcribe (or translate-to-English, when `translate` is true) an audio file.
    /// `language` is an optional ISO-639-1 code; nil/empty means auto-detect.
    func transcribe(fileURL: URL,
                    language: String? = nil,
                    translate: Bool = false,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
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
                fileURL: fileURL, language: language, translate: translate, onProgress: onProgress
            )
        case .qwen3asr:
            return try await qwenProvider.transcribeFile(
                fileURL: fileURL, language: language, translate: translate, onProgress: onProgress
            )
        case .whisper:
            let keepNemotron = liveStateLock.withLock { liveNemotronActive }  // live session is using it
            if !keepNemotron {
                Task { await nemotronProvider.unloadModel() }
            }
            return try await whisperProvider.transcribeFile(
                fileURL: fileURL, language: language, translate: translate, onProgress: onProgress
            )
        }
    }

    // MARK: - Chunk Transcription (Live/Streaming)

    /// Transcribe raw 16kHz mono PCM Float32 samples directly (used for live transcription during recording).
    /// Uses the live model selection (falling back to the main model) and runs on a background queue.
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }

        switch resolveLiveEngine() {
        case .nemotron:
            return try await nemotronProvider.transcribeChunk(samples: samples)
        case .qwen3asr:
            return try await qwenProvider.transcribeChunk(samples: samples)
        case .whisper:
            return try await whisperProvider.transcribeChunk(samples: samples)
        }
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
        }
    }

    // MARK: - Static Queries（UI / API 层继续使用，行为不变）

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
        }
    }
#endif
}
