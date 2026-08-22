import Foundation
import AVFoundation

enum AudioLoader {
    /// 分块解码回调类型：每块为 16kHz mono PCM 采样（顺序、不重叠）。
    /// 返回 false 可提前终止解码（取消场景）。
    typealias SampleChunkHandler = ([Float]) -> Bool

    /// Load any audio/video file as 16 kHz mono PCM Float32 samples.
    ///
    /// Tries AVFoundation first (native, fast, no external process). If that can't
    /// open the container — notably WebM/Opus produced by browser `MediaRecorder`,
    /// which macOS can't decode — it falls back to `ffmpeg` when available.
    static func loadSamples(url: URL) async throws -> [Float] {
        var all: [Float] = []
        all.reserveCapacity(16000 * 300)   // 预留 5 分钟容量，减少增长拷贝
        try await loadSamplesChunked(url: url, chunkSamples: 16000 * 30) { chunk in
            all.append(contentsOf: chunk)
            return true
        }
        return all
    }

    /// 流式分块解码：每凑满 chunkSamples 回调一次，消费方边收边喂，
    /// 避免长文件「解码全量数组 + 喂入拷贝」的双倍峰值内存。
    /// AVFoundation 路径原生分块；ffmpeg 路径保持整文件解码后一次回调。
    static func loadSamplesChunked(url: URL,
                                   chunkSamples: Int = 16000 * 30,
                                   onChunk: SampleChunkHandler) async throws {
        do {
            try await loadViaAVAssetChunked(url: url, chunkSamples: chunkSamples, onChunk: onChunk)
        } catch let avError {
            do {
                // ffmpeg 兜底：管道整读后按块回调（峰值与旧实现相同，
                // 但消费方接口统一；ffmpeg 无原生流式读取价值——进程输出）。
                let samples = try await loadViaFFmpeg(url: url)
                var offset = 0
                while offset < samples.count {
                    let end = min(offset + chunkSamples, samples.count)
                    if !onChunk(Array(samples[offset..<end])) { return }
                    offset = end
                }
                if samples.isEmpty { onChunk([]) }
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

    private static func loadViaAVAssetChunked(url: URL,
                                              chunkSamples: Int,
                                              onChunk: SampleChunkHandler) async throws {
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

        var pending: [Float] = []
        pending.reserveCapacity(chunkSamples)
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
                pending.append(contentsOf: buf)
            }
            // 凑满一块即回调：消费方边收边喂，峰值内存 = 单块 + 解码缓冲。
            if pending.count >= chunkSamples {
                if !onChunk(pending) {
                    reader.cancelReading()
                    return
                }
                pending.removeAll(keepingCapacity: true)
            }
        }

        // A reader error mid-stream (e.g. a container AVFoundation half-supports) should
        // fall through to the ffmpeg fallback rather than returning a truncated result.
        if reader.status == .failed {
            throw reader.error ?? TranscriptionError.processFailed("Audio decoding failed")
        }

        if !pending.isEmpty {
            onChunk(pending)
        } else if pending.isEmpty && reader.status == .completed {
            // 空文件：交给消费方判定（保持旧行为的报错语义由调用方处理）。
        }
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
