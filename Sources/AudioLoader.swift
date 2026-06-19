import Foundation
import AVFoundation

enum AudioLoader {
    /// Load any audio/video file as 16 kHz mono PCM Float32 samples.
    ///
    /// Tries AVFoundation first (native, fast, no external process). If that can't
    /// open the container — notably WebM/Opus produced by browser `MediaRecorder`,
    /// which macOS can't decode — it falls back to `ffmpeg` when available.
    static func loadSamples(url: URL) async throws -> [Float] {
        do {
            return try await loadViaAVAsset(url: url)
        } catch let avError {
            do {
                return try await loadViaFFmpeg(url: url)
            } catch is FFmpegUnavailable {
                let ext = url.pathExtension.isEmpty ? "unknown" : url.pathExtension.lowercased()
                throw TranscriptionError.processFailed(
                    "Couldn't decode this audio (\(ext)). macOS can't read it natively; "
                    + "install ffmpeg (e.g. `brew install ffmpeg`) to support WebM/Opus and more, "
                    + "or send WAV, MP3, M4A, or FLAC. (\(avError.localizedDescription))")
            }
        }
    }

    // MARK: - AVFoundation path

    private static func loadViaAVAsset(url: URL) async throws -> [Float] {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw TranscriptionError.processFailed("No audio track found in file")
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? TranscriptionError.processFailed("Failed to start reading audio")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            _ = data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: ptr.baseAddress!)
            }
            let floatCount = length / MemoryLayout<Float>.size
            data.withUnsafeBytes { ptr in
                let buf = UnsafeBufferPointer(
                    start: ptr.baseAddress!.assumingMemoryBound(to: Float.self),
                    count: floatCount
                )
                samples.append(contentsOf: buf)
            }
        }

        // A reader error mid-stream (e.g. a container AVFoundation half-supports) should
        // fall through to the ffmpeg fallback rather than returning a truncated result.
        if reader.status == .failed {
            throw reader.error ?? TranscriptionError.processFailed("Audio decoding failed")
        }

        guard !samples.isEmpty else {
            throw TranscriptionError.processFailed("Audio file produced no samples")
        }

        return samples
    }

    // MARK: - ffmpeg fallback

    private struct FFmpegUnavailable: Error {}

    private static func loadViaFFmpeg(url: URL) async throws -> [Float] {
        guard let ffmpeg = findFFmpeg() else { throw FFmpegUnavailable() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runFFmpeg(ffmpeg, url: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Decode `url` to 16 kHz mono float32 PCM via ffmpeg, reading raw samples from stdout.
    private static func runFFmpeg(_ ffmpegPath: String, url: URL) throws -> [Float] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-nostdin", "-loglevel", "error",
            "-i", url.path,
            "-ar", "16000", "-ac", "1", "-f", "f32le", "-",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw TranscriptionError.processFailed("Couldn't launch ffmpeg: \(error.localizedDescription)")
        }

        // Drain stdout fully before waiting. `-loglevel error` keeps stderr tiny, so it
        // can't fill its pipe buffer and deadlock while we read stdout.
        let pcm = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionError.processFailed(
                "ffmpeg couldn't decode the audio\(err.isEmpty ? "" : ": \(err)")")
        }
        guard !pcm.isEmpty else {
            throw TranscriptionError.processFailed("ffmpeg produced no audio samples")
        }

        return pcm.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Locate an ffmpeg binary. GUI apps launched from Finder have a minimal PATH, so
    /// check the usual Homebrew/system locations first, then any PATH entry.
    private static func findFFmpeg() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",   // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",      // Intel Homebrew
            "/usr/bin/ffmpeg",
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let path = String(dir) + "/ffmpeg"
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
}
