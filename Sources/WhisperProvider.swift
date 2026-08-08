import Foundation
import CWhisper

/// WhisperProvider：whisper.cpp（CWhisper 桥接）适配层。
///
/// 包装 CWhisper 的全部会话状态与 1.4 TranscriptionService whisper 分支逻辑
/// （主/实时双上下文、串行队列、进度回调、语言检测），对外暴露统一
/// ASRProvider 接口。内部推理代码未改动，仅迁移位置。
final class WhisperProvider: @unchecked Sendable, ASRProvider {
    private var ctx: OpaquePointer?
    private var loadedModelPath: String?
    /// Dedicated context for the live-transcription model, loaded only when the
    /// user picked a live model different from the main one. Both contexts can
    /// coexist so a file transcription (big model) and live chunks (small model)
    /// interleaving on the queue don't reload models on every alternation.
    private var liveCtx: OpaquePointer?
    private var loadedLiveModelPath: String?
    /// Serial queue to ensure only one whisper_full() runs at a time (ctx is not thread-safe).
    private let whisperQueue = DispatchQueue(label: "com.whisperasr.whisper", qos: .userInitiated)

    var engine: ASRProviderEngine { .whisper }

    deinit {
        if let ctx { whisper_free(ctx) }
        if let liveCtx { whisper_free(liveCtx) }
    }

    // MARK: - ASRProvider

    /// 预加载实时转录模型（录制开始时调用，避免首个分块等待模型加载）。
    /// 等待队列中的转录完成后加载。
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            whisperQueue.async {
                do {
                    _ = try self.ensureLiveModelLoaded()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 显式加载主转录模型。幂等。
    func loadModel() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            whisperQueue.async {
                do {
                    _ = try self.ensureModelLoaded()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 释放主上下文。Serialize with any in-flight whisper_full; if the process
    /// exits before this runs the OS reclaims the context anyway. Frees only the
    /// main context — a live session's dedicated context stays loaded.
    func unloadModel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            whisperQueue.async {
                if let ctx = self.ctx {
                    whisper_free(ctx)
                    self.ctx = nil
                    self.loadedModelPath = nil
                }
                continuation.resume()
            }
        }
    }

    /// 释放实时会话的专用上下文（录音结束时调用）。仅由 TranscriptionService
    /// 在结束实时会话时调用；不在 ASRProvider 协议内。
    func unloadLiveModel() {
        whisperQueue.async {
            if let liveCtx = self.liveCtx {
                whisper_free(liveCtx)
                self.liveCtx = nil
                self.loadedLiveModelPath = nil
            }
        }
    }

    /// 状态快照在 whisper 串行队列上读取，保证与模型生命周期一致。
    func status() async -> ASRProviderStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<ASRProviderStatus, Never>) in
            whisperQueue.async {
                let status: ASRProviderStatus
                if let loadedModelPath = self.loadedModelPath {
                    status = .loaded(path: loadedModelPath)
                } else if let loadedLiveModelPath = self.loadedLiveModelPath {
                    status = .loaded(path: loadedLiveModelPath)
                } else {
                    status = .idle
                }
                continuation.resume(returning: status)
            }
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

        return try await withCheckedThrowingContinuation { continuation in
            self.whisperQueue.async {
                let ctx: OpaquePointer
                do {
                    ctx = try self.ensureModelLoaded()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                var (params, langCStr, promptCStr) = self.makeBaseParams(language: language, translate: translate)
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

                // Run transcription
                let result = samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }

                // Release progress box
                Unmanaged<ProgressBox>.fromOpaque(progressPtr).release()

                if result != 0 {
                    continuation.resume(throwing: TranscriptionError.processFailed("whisper_full returned error \(result)"))
                    return
                }

                // Extract segments
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
                let langId = whisper_full_lang_id(ctx)
                if langId >= 0, let langPtr = whisper_lang_str(langId) {
                    detected = String(cString: langPtr)
                }

                continuation.resume(returning: TranscriptionResult(
                    text: fullText,
                    segments: segments,
                    detectedLanguage: detected
                ))
            }
        }
    }

    // MARK: - 分块转录（实时）

    /// Transcribe raw 16kHz mono PCM Float32 samples directly (used for live
    /// transcription during recording). Uses the live model selection (falling
    /// back to the main model) and runs on a background queue.
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        return try await withCheckedThrowingContinuation { continuation in
            self.whisperQueue.async {
                let ctx: OpaquePointer
                do {
                    ctx = try self.ensureLiveModelLoaded()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let liveThreads = min(4, max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 4)))
                let (params, langCStr, promptCStr) = self.makeBaseParams(threadCount: liveThreads)
                defer {
                    free(langCStr)
                    if let promptCStr { free(promptCStr) }
                }

                let result = samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }

                if result != 0 {
                    continuation.resume(throwing: TranscriptionError.processFailed("whisper_full returned error \(result)"))
                    return
                }

                let nSegments = whisper_full_n_segments(ctx)
                var segments: [TranscriptionSegment] = []
                var fullText = ""

                for i in 0..<nSegments {
                    let t0 = whisper_full_get_segment_t0(ctx, i)
                    let t1 = whisper_full_get_segment_t1(ctx, i)
                    let text: String
                    if let cStr = whisper_full_get_segment_text(ctx, i) {
                        text = String(cString: cStr)
                    } else {
                        text = ""
                    }

                    segments.append(TranscriptionSegment(
                        start: Double(t0) / 100.0,
                        end: Double(t1) / 100.0,
                        text: text
                    ))
                    fullText += text
                }

                continuation.resume(returning: TranscriptionResult(
                    text: fullText,
                    segments: segments
                ))
            }
        }
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

    /// Load (or re-load, when the resolved path changed) the model and return the context.
    /// MUST run on `whisperQueue`: reloading frees the previous context, which would
    /// crash a whisper_full running concurrently on the queue if done anywhere else.
    @discardableResult
    private func ensureModelLoaded() throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(whisperQueue))
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
    /// instead of loading the same weights twice. MUST run on `whisperQueue`.
    private func ensureLiveModelLoaded() throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(whisperQueue))
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
