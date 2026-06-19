import Foundation
import CWhisper

final class TranscriptionService: @unchecked Sendable {
    private var ctx: OpaquePointer?
    private var loadedModelPath: String?
    /// Serial queue to ensure only one whisper_full() runs at a time (ctx is not thread-safe).
    private let whisperQueue = DispatchQueue(label: "com.whisperasr.whisper", qos: .userInitiated)

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    func shutdown() {
        if let ctx {
            whisper_free(ctx)
            self.ctx = nil
            self.loadedModelPath = nil
        }
    }

    /// Transcribe (or translate-to-English, when `translate` is true) an audio file.
    /// `language` is an optional ISO-639-1 code; nil/empty means auto-detect.
    func transcribe(fileURL: URL,
                    language: String? = nil,
                    translate: Bool = false,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        try ensureModelLoaded()
        guard let ctx else {
            throw TranscriptionError.scriptNotFound("Model not loaded")
        }

        let samples = try await AudioLoader.loadSamples(url: fileURL)

        return try await withCheckedThrowingContinuation { continuation in
            self.whisperQueue.async {
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
    /// This reuses the already-loaded whisper model and runs on a background queue.
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        try ensureModelLoaded()
        guard let ctx else {
            throw TranscriptionError.scriptNotFound("Model not loaded")
        }
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.whisperQueue.async {
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

    /// Ensure the whisper model is loaded (public access for pre-loading during recording start).
    func preloadModel() throws {
        try ensureModelLoaded()
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

    private func ensureModelLoaded() throws {
        let path = resolveModelPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.scriptNotFound(
                "Model not found at: \(path)\n\n" +
                "Download a model in Settings → Speech Recognition Models."
            )
        }
        if loadedModelPath != path {
            if let ctx { whisper_free(ctx) }

            var cparams = whisper_context_default_params()
            cparams.use_gpu = true  // Metal GPU acceleration
            cparams.flash_attn = true

            ctx = path.withCString { whisper_init_from_file_with_params($0, cparams) }
            guard ctx != nil else {
                throw TranscriptionError.processFailed("Failed to load whisper model from: \(path)")
            }
            loadedModelPath = path
        }
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
