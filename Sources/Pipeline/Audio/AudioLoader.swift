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
        // 取消传播：runFFmpeg 在后台线程阻塞等待子进程，Task 取消必须能
        // 立刻终止 ffmpeg——否则转录队列被取消后仍挂到子进程自己结束。
        let box = FFmpegProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runFFmpeg(ffmpeg, url: url, box: box))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// ffmpeg 子进程的跨线程句柄。
    ///
    /// 取消（`Task.cancel`）发生在任意线程，而 `runFFmpeg` 正阻塞在轮询/管道
    /// 读取里；需要一个加锁的中转点把「终止子进程」送达那里，并让已取消的
    /// 启动被立刻掐断（否则取消后照样跑完整个解码）。
    private final class FFmpegProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// 安装子进程；若安装前已被取消则立即终止并返回 false。
        func install(_ process: Process) -> Bool {
            lock.lock()
            let alreadyCancelled = cancelled
            if !alreadyCancelled { self.process = process }
            lock.unlock()
            if alreadyCancelled { terminate(process) }
            return !alreadyCancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if let running { terminate(running) }
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// 后台线程持续排空一个管道，直到 EOF（子进程退出或被终止）。
    ///
    /// **这是防死锁的关键**：管道内核缓冲只有 64KB，子进程写满后 write 阻塞；
    /// 若像此前那样等 `waitUntilExit()` 之后才 `readDataToEndOfFile()`，父进程
    /// 等子进程退出、子进程等父进程读走缓冲 → 双方互等，转录队列永久挂起
    /// （长文件必然触发：16kHz f32 每秒 64KB，1 秒输出即写满）。
    ///
    /// stdout 边读边转 Float（而不是先攒整块 Data 再转）：长文件峰值内存
    /// = 样本数组本身，不额外翻倍。追加只发生在排空线程，读取方在
    /// `finished` 信号之后读 → 信号量的 signal/wait 构成 happens-before。
    private final class FFmpegStdoutDrain: @unchecked Sendable {
        private var samples: [Float] = []
        private var remainder = Data()
        private let finished = DispatchSemaphore(value: 0)

        func run(handle: FileHandle) {
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                append(chunk)
            }
            finished.signal()
        }

        private func append(_ chunk: Data) {
            let data = remainder.isEmpty ? chunk : (remainder + chunk)
            remainder = Data()
            let floatCount = data.count / MemoryLayout<Float>.size
            let processableBytes = floatCount * MemoryLayout<Float>.size
            if processableBytes > 0 {
                data.prefix(processableBytes).withUnsafeBytes { raw in
                    if let ptr = raw.baseAddress?.assumingMemoryBound(to: Float.self) {
                        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: floatCount))
                    }
                }
            }
            let leftover = data.count - processableBytes
            if leftover > 0 { remainder = data.suffix(leftover) }
        }

        /// 等待排空线程收尾（返回 false = 超时，管道仍未 EOF）。
        func waitUntilDrained(seconds: Double) -> Bool {
            finished.wait(timeout: .now() + seconds) == .success
        }

        var collected: [Float] { samples }
    }

    /// 后台线程持续排空 stderr 文本（同样防死锁；`-loglevel error` 平时无输出，
    /// 但解码告警/损坏文件可能刷屏，写满 64KB 就足以卡死）。
    private final class FFmpegStderrDrain: @unchecked Sendable {
        private var data = Data()
        private let finished = DispatchSemaphore(value: 0)

        func run(handle: FileHandle) {
            while true {
                let chunk = handle.readData(ofLength: 16 * 1024)
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            finished.signal()
        }

        func waitUntilDrained(seconds: Double) -> Bool {
            finished.wait(timeout: .now() + seconds) == .success
        }

        /// 错误信息只用于报错文案：截断到 4KB 防止把巨量告警灌进 UI。
        var text: String {
            let clipped = data.count > 4096 ? data.prefix(4096) : data
            return String(decoding: clipped, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 解码超时上限：ffmpeg 的探流 + 解码吞吐按 **≥256KB/s 输入**估算
    /// （慢速容器/网络盘/长 GOP 都留足余量），再加 60s 启动开销；
    /// 下限 120s（小文件也有进程启动与探流成本），上限 1 小时
    /// （超长录音仍能完成，但不再允许无限挂起）。
    /// 用文件字节数而非 AVAsset 时长：走到 ffmpeg 兜底说明 AVFoundation
    /// 读不了该容器，时长多半也拿不到。
    private static func ffmpegTimeout(for url: URL) -> TimeInterval {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
        let estimated = bytes / (256 * 1024)
        return min(3_600, max(120, estimated + 60))
    }

    /// 终止子进程：先 SIGTERM（给 ffmpeg 清理机会），宽限 2s 后 SIGKILL
    /// 兜底（ffmpeg 偶发在写管道时忽略 SIGTERM，只 SIGTERM 会二次挂起）。
    private static func terminate(_ proc: Process) {
        guard proc.isRunning else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    /// Decode `url` to 16 kHz mono float32 PCM via ffmpeg, reading raw samples from stdout.
    private static func runFFmpeg(_ ffmpegPath: String,
                                 url: URL,
                                 box: FFmpegProcessBox) throws -> [Float] {
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

        let stdoutDrain = FFmpegStdoutDrain()
        let stderrDrain = FFmpegStderrDrain()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        // 先起排空线程再 run()：子进程一启动就可能开始写，排空必须已经在读。
        DispatchQueue.global(qos: .userInitiated).async { stdoutDrain.run(handle: outHandle) }
        DispatchQueue.global(qos: .userInitiated).async { stderrDrain.run(handle: errHandle) }

        do {
            try proc.run()
        } catch {
            outHandle.closeFile()
            errHandle.closeFile()
            _ = stdoutDrain.waitUntilDrained(seconds: 2)
            _ = stderrDrain.waitUntilDrained(seconds: 2)
            throw TranscriptionError.processFailed("Couldn't launch ffmpeg: \(error.localizedDescription)")
        }

        // 已取消（取消发生在 run() 之前）：install 会直接终止刚启动的子进程。
        guard box.install(proc) else {
            _ = stdoutDrain.waitUntilDrained(seconds: 5)
            _ = stderrDrain.waitUntilDrained(seconds: 5)
            throw CancellationError()
        }

        // 等待子进程：轮询而非 waitUntilExit() 阻塞——waitUntilExit 不可中断，
        // 超时与取消都无法生效（这正是「队列永久挂起」的另一半原因）。
        let deadline = Date().addingTimeInterval(ffmpegTimeout(for: url))
        var timedOut = false
        while proc.isRunning {
            if box.isCancelled {
                terminate(proc)
                break
            }
            if Date() >= deadline {
                timedOut = true
                terminate(proc)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !proc.isRunning { proc.waitUntilExit() }

        // 子进程已退出/被杀 → 管道写端关闭 → 排空线程读到 EOF 收尾。
        // 超时上限 5s：正常情况在毫秒级返回。
        _ = stdoutDrain.waitUntilDrained(seconds: 5)
        _ = stderrDrain.waitUntilDrained(seconds: 5)
        outHandle.closeFile()
        errHandle.closeFile()

        if box.isCancelled { throw CancellationError() }
        if timedOut {
            let err = stderrDrain.text
            throw TranscriptionError.processFailed(
                "ffmpeg timed out after \(Int(ffmpegTimeout(for: url)))s decoding "
                + "\(url.lastPathComponent)\(err.isEmpty ? "" : ": \(err)")")
        }

        let samples = stdoutDrain.collected
        guard proc.terminationStatus == 0 else {
            let err = stderrDrain.text
            throw TranscriptionError.processFailed(
                "ffmpeg couldn't decode the audio\(err.isEmpty ? "" : ": \(err)")")
        }
        guard !samples.isEmpty else {
            throw TranscriptionError.processFailed("ffmpeg produced no audio samples")
        }

        return samples
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
