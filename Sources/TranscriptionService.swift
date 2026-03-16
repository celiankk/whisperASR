import Foundation
import CWhisper

final class TranscriptionService: @unchecked Sendable {
    private var ctx: OpaquePointer?
    private var loadedModelPath: String?

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

    func transcribe(fileURL: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        try ensureModelLoaded()
        guard let ctx else {
            throw TranscriptionError.scriptNotFound("Model not loaded")
        }

        let samples = try await AudioLoader.loadSamples(url: fileURL)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Configure transcription parameters
                var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                params.print_progress = false
                params.print_realtime = false
                params.print_timestamps = false
                params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))

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

                continuation.resume(returning: TranscriptionResult(
                    text: fullText,
                    segments: segments
                ))
            }
        }
    }

    // MARK: - Model Management

    private func ensureModelLoaded() throws {
        let path = resolveModelPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.scriptNotFound(
                "Model not found at: \(path)\n\n" +
                "Convert the Breeze-ASR-25 model first:\n" +
                "  bash Scripts/convert_model.sh"
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
        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return custom
        }

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
