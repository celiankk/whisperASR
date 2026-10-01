import Foundation
import CWhisper

/// WhisperProvider：whisper.cpp（CWhisper 桥接）适配层。
///
/// 包装 CWhisper 的全部会话状态与 1.4 TranscriptionService whisper 分支逻辑
/// （主/实时双上下文、串行执行、进度回调、语言检测），对外暴露统一
/// ASRProvider 接口。内部推理代码未改动，仅迁移位置。
///
/// P0 actor 化：原 `DispatchQueue` 串行 + `@unchecked Sendable` 手工同步
/// 全部由 actor 隔离取代——ctx/loadedPath 状态与 whisper_full 串行化是
/// 同一个执行域，无需队列跳板与 continuation 包装。
/// 注意：whisper_full 是长阻塞调用，会占住本 actor 的协作线程数秒——
/// 与旧实现占用专用串行队列线程等价（实时循环本就串行等待）。
actor WhisperProvider: ASRProvider {
    private var ctx: OpaquePointer?
    private var loadedModelPath: String?
    /// Dedicated context for the live-transcription model, loaded only when the
    /// user picked a live model different from the main one. Both contexts can
    /// coexist so a file transcription (big model) and live chunks (small model)
    /// interleaving on the queue don't reload models on every alternation.
    private var liveCtx: OpaquePointer?
    private var loadedLiveModelPath: String?

    /// 协议要求 `{ get }`：actor 不可变 let（Sendable 类型）天然 nonisolated。
    nonisolated let engine: ASRProviderEngine = .whisper

    deinit {
        if let ctx { whisper_free(ctx) }
        if let liveCtx { whisper_free(liveCtx) }
    }

    // MARK: - ASRProvider

    /// 预加载实时转录模型（录制开始时调用，避免首个分块等待模型加载）。
    /// 等待队列中的转录完成后加载。
    func prepare() async throws {
        _ = try ensureLiveModelLoaded()
    }

    /// 显式加载主转录模型。幂等。
    func loadModel() async throws {
        _ = try ensureModelLoaded()
    }

    /// 释放主上下文。Serialize with any in-flight whisper_full（actor 隔离
    /// 保证）；if the process exits before this runs the OS reclaims the
    /// context anyway. Frees only the main context — a live session's
    /// dedicated context stays loaded.
    func unloadModel() async {
        if let existing = ctx {
            whisper_free(existing)
            ctx = nil
            loadedModelPath = nil
        }
    }

    /// 释放实时会话的专用上下文（录音结束时调用）。仅由 TranscriptionService
    /// 在结束实时会话时调用；不在 ASRProvider 协议内。
    /// 同步签名保持不变（调用方在非 async 上下文），经 Task 跳入 actor。
    nonisolated func unloadLiveModel() {
        Task { await self.unloadLiveContext() }
    }

    private func unloadLiveContext() {
        if let existing = liveCtx {
            whisper_free(existing)
            liveCtx = nil
            loadedLiveModelPath = nil
        }
    }

    /// 状态快照在 actor 隔离内读取，保证与模型生命周期一致。
    func status() async -> ASRProviderStatus {
        if let loadedModelPath {
            return .loaded(path: loadedModelPath)
        } else if let loadedLiveModelPath {
            return .loaded(path: loadedLiveModelPath)
        } else {
            return .idle
        }
    }

    // MARK: - 文件转录

    /// Transcribe (or translate-to-English, when `translate` is true) an audio file.
    /// `language` is an optional ISO-639-1 code; nil/empty means auto-detect.
    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        let samples = try await AudioLoader.loadSamples(url: fileURL)

        let ctx: OpaquePointer = try ensureModelLoaded()

        var (params, langCStr, promptCStr) = makeBaseParams(language: language, translate: translate)
        defer {
            free(langCStr)
            if let promptCStr { free(promptCStr) }
        }

        // Progress callback
        let progressPtr = Unmanaged.passRetained(ProgressBox(handler: onProgress)).toOpaque()
        params.progress_callback_user_data = progressPtr
        params.progress_callback = { (_: OpaquePointer?, _: OpaquePointer?, progress: Int32, userData: UnsafeMutableRawPointer?) in
            guard let userData else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue()
            let value = Double(progress) / 100.0
            DispatchQueue.main.async {
                box.handler(value)
            }
        }

        // Run transcription（输入桶化：0.5s 量子对齐稳定推理形状）。
        let input = InputBucketing.padded(samples)
        let result = input.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }

        // Release progress box
        Unmanaged<ProgressBox>.fromOpaque(progressPtr).release()

        if result != 0 {
            throw TranscriptionError.processFailed("whisper_full returned error \(result)")
        }

        return Self.extractResult(ctx: ctx, detectedLanguage: true)
    }

    // MARK: - 分块转录（实时）

    /// 协议单参重载：转发至带绝对区间版本（无状态引擎忽略区间）。
    func transcribeChunk(samples: ArraySlice<Float>) async throws -> TranscriptionResult {
        try await transcribeChunk(samples: samples, absoluteRange: nil)
    }

    /// Transcribe raw 16kHz mono PCM Float32 samples directly (used for live
    /// transcription during recording). Uses the live model selection (falling
    /// back to the main model) and runs serialized on the actor.
    /// 输入是零拷贝切片（P0 链路）；withUnsafeBufferPointer 对切片给出
    /// 指向其存储区间的指针，直接喂 whisper_full，不经 Array 构造。
    /// `absoluteRange` is accepted for protocol conformance but ignored by the
    /// stateless whisper engine (each chunk is independently transcribed).
    func transcribeChunk(samples: ArraySlice<Float>, absoluteRange: Range<Int>?) async throws -> TranscriptionResult {
        let ctx: OpaquePointer = try ensureLiveModelLoaded()

        let liveThreads = min(4, max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 4)))
        // 实时识别语言：设置页「识别语言」（nil = 自动检测）。
        let (params, langCStr, promptCStr) = makeBaseParams(
            threadCount: liveThreads,
            language: ConfigurationManager.shared.asr.effectiveASRLanguage)
        defer {
            free(langCStr)
            if let promptCStr { free(promptCStr) }
        }

        let result = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }

        if result != 0 {
            throw TranscriptionError.processFailed("whisper_full returned error \(result)")
        }

        return Self.extractResult(ctx: ctx, detectedLanguage: false)
    }

    // MARK: - Params Configuration

    /// Create base whisper params. `language` nil/empty means auto-detect; when
    /// `translate` is true whisper translates the audio to English.
    /// Caller must free the returned C string pointers after whisper_full completes.
    /// ASR Prompt（热词）经 ASRPromptManager 注入 initial_prompt（无 Prompt 时为空）。
    private func makeBaseParams(threadCount: Int32? = nil,
                                language: String? = nil,
                                translate: Bool = false) -> (whisper_full_params, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.n_threads = threadCount ?? max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))
        params.translate = translate

        let lang = (language?.isEmpty == false) ? language! : "auto"
        let langCStr = strdup(lang)
        params.language = UnsafePointer(langCStr)

        // ASR Prompt 注入（关闭/无内容时为 nil，行为与 1.4 完全一致）。
        var promptCStr: UnsafeMutablePointer<CChar>? = nil
        if let prompt = ASRPromptManager.shared.currentPrompt, !prompt.isEmpty {
            promptCStr = strdup(prompt)
            params.initial_prompt = UnsafePointer(promptCStr)
        }

        return (params, langCStr, promptCStr)
    }

    /// Returns all languages supported by the loaded whisper.cpp library.
    static func availableLanguages() -> [(code: String, name: String)] {
        var langs: [(code: String, name: String)] = []
        let maxId = Int(whisper_lang_max_id())
        for i in 0...maxId {
            if let codePtr = whisper_lang_str(Int32(i)),
               let namePtr = whisper_lang_str_full(Int32(i)) {
                langs.append((code: String(cString: codePtr), name: String(cString: namePtr)))
            }
        }
        return langs
    }

    // MARK: - Model Management

    /// 读取 whisper 结果段（文件/分块共用；detectedLanguage 仅文件路径开）。
    /// 纯 ctx 读取，无隔离态访问 → static。
    private static func extractResult(ctx: OpaquePointer, detectedLanguage: Bool) -> TranscriptionResult {
        let nSegments = whisper_full_n_segments(ctx)
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        for i in 0..<nSegments {
            let t0 = whisper_full_get_segment_t0(ctx, i)  // centiseconds (10ms units)
            let t1 = whisper_full_get_segment_t1(ctx, i)
            let text: String
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                text = String(cString: cStr)
            } else {
                text = ""
            }

            segments.append(TranscriptionSegment(
                start: Double(t0) / 100.0,  // convert centiseconds → seconds
                end: Double(t1) / 100.0,
                text: text
            ))
            fullText += text
        }

        // Whisper's auto-detected language for the audio.
        var detected: String? = nil
        if detectedLanguage {
            let langId = whisper_full_lang_id(ctx)
            if langId >= 0, let langPtr = whisper_lang_str(langId) {
                detected = String(cString: langPtr)
            }
        }

        return TranscriptionResult(
            text: fullText,
            segments: segments,
            detectedLanguage: detected
        )
    }

    /// Load (or re-load, when the resolved path changed) the model and return the context.
    /// Actor-isolated: reloading frees the previous context, which would crash a
    /// whisper_full running concurrently if done anywhere else (旧实现靠
    /// whisperQueue 串行保证，现由 actor 隔离取代).
    @discardableResult
    private func ensureModelLoaded() throws -> OpaquePointer {
        let path = ModelPathResolver.resolveModelPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.modelNotFound(
                "Model not found at: \(path)\n\n" +
                "Download a model in Settings → Speech Recognition Models."
            )
        }
        if loadedModelPath != path {
            if let ctx { whisper_free(ctx) }
            ctx = nil
            loadedModelPath = nil
            ctx = try Self.loadContext(path: path)
            loadedModelPath = path
        }
        guard let ctx else {
            throw TranscriptionError.processFailed("Model not loaded")
        }
        return ctx
    }

    /// Live-model counterpart of `ensureModelLoaded()`. When the live selection
    /// resolves to the same file as the main model, the main context is shared
    /// instead of loading the same weights twice. Actor-isolated.
    private func ensureLiveModelLoaded() throws -> OpaquePointer {
        let livePath = ModelPathResolver.resolveLiveModelPath()
        if livePath == ModelPathResolver.resolveModelPath() {
            // Drop a stale dedicated context (live selection changed mid-session).
            if let liveCtx {
                whisper_free(liveCtx)
                self.liveCtx = nil
                loadedLiveModelPath = nil
            }
            return try ensureModelLoaded()
        }
        guard FileManager.default.fileExists(atPath: livePath) else {
            throw TranscriptionError.modelNotFound(
                "Live transcription model not found at: \(livePath)\n\n" +
                "Download a model in Settings → Speech Recognition Models."
            )
        }
        if loadedLiveModelPath != livePath {
            if let liveCtx { whisper_free(liveCtx) }
            liveCtx = nil
            loadedLiveModelPath = nil
            liveCtx = try Self.loadContext(path: livePath)
            loadedLiveModelPath = livePath
        }
        guard let liveCtx else {
            throw TranscriptionError.processFailed("Model not loaded")
        }
        return liveCtx
    }

    private static func loadContext(path: String) throws -> OpaquePointer {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true  // Metal GPU acceleration
        cparams.flash_attn = true

        guard let ctx = path.withCString({ whisper_init_from_file_with_params($0, cparams) }) else {
            throw TranscriptionError.processFailed("Failed to load whisper model from: \(path)")
        }
        return ctx
    }
}

// Box for passing progress handler through C callback
private class ProgressBox {
    let handler: @Sendable (Double) -> Void
    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }
}
