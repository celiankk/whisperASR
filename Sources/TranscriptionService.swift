import Foundation
import CWhisper

final class TranscriptionService: @unchecked Sendable {
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
    /// Core ML / ANE engine for Nemotron model bundles (directory models).
    private let nemotron = NemotronEngine()
    /// True while a live session runs on the Nemotron engine — blocks the
    /// "unload nemotron when file-transcribing with whisper" eviction below.
    private let liveStateLock = NSLock()
    private var liveNemotronActive = false

    /// Which engine the currently selected model runs on.
    private enum ResolvedEngine {
        case whisper(path: String)
        case nemotron(directory: String)
    }

    /// Whisper models are single files; Nemotron bundles are directories.
    private func resolveEngine() -> ResolvedEngine {
        Self.engine(forPath: resolveModelPath())
    }

    /// Engine for the live-transcription model selection.
    private func resolveLiveEngine() -> ResolvedEngine {
        Self.engine(forPath: resolveLiveModelPath())
    }

    private static func engine(forPath path: String) -> ResolvedEngine {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .nemotron(directory: path)
        }
        return .whisper(path: path)
    }

    deinit {
        if let ctx { whisper_free(ctx) }
        if let liveCtx { whisper_free(liveCtx) }
    }

    func shutdown() {
        unloadLiveModel()
        unloadWhisper()
        Task { await self.nemotron.unload() }
    }

    /// Serialize with any in-flight whisper_full; if the process exits before
    /// this runs the OS reclaims the context anyway. Frees only the main
    /// context — a live session's dedicated context stays loaded.
    private func unloadWhisper() {
        whisperQueue.async {
            if let ctx = self.ctx {
                whisper_free(ctx)
                self.ctx = nil
                self.loadedModelPath = nil
            }
        }
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

        whisperQueue.async {
            if let liveCtx = self.liveCtx {
                whisper_free(liveCtx)
                self.liveCtx = nil
                self.loadedLiveModelPath = nil
            }
        }
        if wasNemotron, case .whisper = resolveEngine() {
            Task { await self.nemotron.unload() }
        }
    }

    /// Transcribe (or translate-to-English, when `translate` is true) an audio file.
    /// `language` is an optional ISO-639-1 code; nil/empty means auto-detect.
    func transcribe(fileURL: URL,
                    language: String? = nil,
                    translate: Bool = false,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        let samples = try await AudioLoader.loadSamples(url: fileURL)

        if case .nemotron(let directory) = resolveEngine() {
            guard !translate else {
                throw TranscriptionError.processFailed(
                    "Translation to English is not supported by the Nemotron model. Select a Whisper model instead."
                )
            }
            unloadWhisper()  // free the main whisper ctx (a live session's context stays)
            try await nemotron.ensureLoaded(directory: URL(fileURLWithPath: directory, isDirectory: true))
            return try await nemotron.transcribe(samples: samples, language: language, onProgress: onProgress)
        }
        let keepNemotron = liveStateLock.withLock { liveNemotronActive }  // live session is using it
        if !keepNemotron {
            Task { await self.nemotron.unload() }
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.whisperQueue.async {
                let ctx: OpaquePointer
                do {
                    ctx = try self.ensureModelLoaded()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                var (params, langCStr) = self.makeBaseParams(language: language, translate: translate)
                defer { free(langCStr) }

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

    // MARK: - Chunk Transcription (Live/Streaming)

    /// Transcribe raw 16kHz mono PCM Float32 samples directly (used for live transcription during recording).
    /// Uses the live model selection (falling back to the main model) and runs on a background queue.
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }

        if case .nemotron(let directory) = resolveLiveEngine() {
            try await nemotron.ensureLoaded(directory: URL(fileURLWithPath: directory, isDirectory: true))
            return try await nemotron.transcribeChunk(samples: samples)
        }

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
                let (params, langCStr) = self.makeBaseParams(threadCount: liveThreads)
                defer { free(langCStr) }

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

    /// Ensure the live-transcription model is loaded (pre-loading at recording
    /// start, to avoid model loading latency on the first chunk). Waits for any
    /// queued transcription, then loads.
    func preloadLiveModel() async throws {
        switch resolveLiveEngine() {
        case .whisper:
            liveStateLock.withLock { liveNemotronActive = false }
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
        case .nemotron(let directory):
            liveStateLock.withLock { liveNemotronActive = true }
            try await nemotron.ensureLoaded(directory: URL(fileURLWithPath: directory, isDirectory: true))
        }
    }

    // MARK: - Params Configuration

    /// Create base whisper params. `language` nil/empty means auto-detect; when
    /// `translate` is true whisper translates the audio to English.
    /// Caller must free the returned C string pointer after whisper_full completes.
    private func makeBaseParams(threadCount: Int32? = nil,
                                language: String? = nil,
                                translate: Bool = false) -> (whisper_full_params, UnsafeMutablePointer<CChar>?) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.n_threads = threadCount ?? max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))
        params.translate = translate

        let lang = (language?.isEmpty == false) ? language! : "auto"
        let langCStr = strdup(lang)
        params.language = UnsafePointer(langCStr)

        return (params, langCStr)
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

    static var appSupportModelPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/Models/ggml-model.bin").path
    }

    /// Check whether a usable model file exists at any known location.
    static func modelExists() -> Bool {
        if let files = try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path),
           files.contains(where: { $0.hasSuffix(".bin") }) {
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

    /// Load (or re-load, when the resolved path changed) the model and return the context.
    /// MUST run on `whisperQueue`: reloading frees the previous context, which would
    /// crash a whisper_full running concurrently on the queue if done anywhere else.
    @discardableResult
    private func ensureModelLoaded() throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(whisperQueue))
        let path = resolveModelPath()
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
        let livePath = resolveLiveModelPath()
        if livePath == resolveModelPath() {
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

    private func resolveModelPath() -> String {
        // Explicitly selected downloaded model (set via Settings or the toolbar picker)
        if let selected = UserDefaults.standard.string(forKey: "selectedModelFile"),
           !selected.isEmpty {
            let selectedPath = ModelCatalog.modelDirectory.appendingPathComponent(selected).path
            if FileManager.default.fileExists(atPath: selectedPath) {
                return selectedPath
            }
        }

        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return custom
        }

        // Check App Support path (where auto-download saves the model)
        let appSupportPath = Self.appSupportModelPath
        if FileManager.default.fileExists(atPath: appSupportPath) {
            return appSupportPath
        }

        // Fallback to project-relative path (development)
        let projectRoot = resolveProjectRoot()
        return (projectRoot as NSString).appendingPathComponent("Models/ggml-model.bin")
    }

    /// Model used for live transcription during recording: the dedicated live
    /// selection (usually a smaller, faster model) when set and present,
    /// otherwise whatever the main resolution picks.
    private func resolveLiveModelPath() -> String {
        if let live = UserDefaults.standard.string(forKey: "liveModelFile"),
           !live.isEmpty {
            let livePath = ModelCatalog.modelDirectory.appendingPathComponent(live).path
            if FileManager.default.fileExists(atPath: livePath) {
                return livePath
            }
        }
        return resolveModelPath()
    }

    private func resolveProjectRoot() -> String {
        let thisFile = #filePath
        let sourcesDir = (thisFile as NSString).deletingLastPathComponent
        return (sourcesDir as NSString).deletingLastPathComponent
    }
}

// Box for passing progress handler through C callback
private class ProgressBox {
    let handler: @Sendable (Double) -> Void
    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }
}
