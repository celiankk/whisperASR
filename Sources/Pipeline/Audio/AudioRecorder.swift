import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation
import os
import CoreGraphics
import Darwin

enum RecordingState: Equatable {
    case idle
    case loading
    case ready
    case recording
    case saving
    case permissionDenied
}

@Observable
class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var state: RecordingState = .idle
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?
    var recordingDuration: TimeInterval = 0
    var error: String?
    var meetingEnded = false
    /// 初值读「音频」设置的默认包含麦克风；浮层内仍可临时切换。
    var includeMicrophone = UserDefaults.standard.bool(forKey: AudioConfiguration.includeMicrophoneKey)
    var onMeetingEnded: (() -> Void)?
    var customRecordingName: String?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var recordingAppName: String?
    private var outputURL: URL?
    private var _hasReceivedSamples = OSAllocatedUnfairLock(initialState: false)
    private var meetingMonitorTimer: Timer?
    private var recordingPID: pid_t?
    private var meetingStarted = false

    // Stream watchdog: detect stalled audio delivery and restart
    private var lastAudioBufferTime = OSAllocatedUnfairLock(initialState: Date())
    private var audioWatchdogTimer: Timer?
    private var recordingApp: SCRunningApplication?
    private var isRestartingStream = false
    /// How long without audio before we consider the stream stalled (seconds).
    private static let audioStallThreshold: TimeInterval = 15

    // Microphone mixing
    private var audioEngine: AVAudioEngine?
    private var micSampleBuffer = OSAllocatedUnfairLock(initialState: [Float]())
    private var isMicActive = false
    private static let maxMicBufferSamples = 48000 * 5 // 5 seconds cap

    // Live transcription: accumulated 16kHz mono PCM samples.
    // Buffer + trimOffset are in a single lock so reads/writes are always atomic.
    private struct PCMState {
        var buffer: [Float] = []
        var trimOffset: Int = 0
    }
    private var pcmState = OSAllocatedUnfairLock(initialState: PCMState())

    // 48kHz → 16kHz resampler for live transcription (AVAudioConverter applies
    // a proper anti-alias low-pass filter; naive decimation aliased above 8kHz).
    private static let pcmSourceFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private static let pcmTargetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    @ObservationIgnored
    private lazy var pcmResampler: AVAudioConverter? = {
        AVAudioConverter(from: AudioRecorder.pcmSourceFormat, to: AudioRecorder.pcmTargetFormat)
    }()
    /// Total number of 16kHz samples accumulated since recording started (absolute count).
    var accumulatedSampleCount: Int {
        pcmState.withLock { $0.trimOffset + $0.buffer.count }
    }

    private static let zoomBundleIDs: Set<String> = ["us.zoom.xos", "us.zoom.videomeeting"]

    // MARK: - Live Transcription PCM Access

    /// Returns a copy of all accumulated 16kHz PCM samples for live transcription.
    func getAccumulatedSamples() -> [Float] {
        pcmState.withLock { Array($0.buffer) }
    }

    /// Returns only the samples from absolute `startIndex` onward — avoids copying the entire
    /// buffer during long recordings (which can be hundreds of MB after 30+ minutes).
    func getSamples(from startIndex: Int) -> [Float] {
        pcmState.withLock { state in
            let bufIndex = startIndex - state.trimOffset
            guard bufIndex >= 0, bufIndex < state.buffer.count else { return [] }
            return Array(state.buffer[bufIndex...])
        }
    }

    /// Returns the samples in the absolute range `[startIndex, endIndex)` — used to copy only the
    /// audio a chunk needs when its end is held back from the live tail.
    func getSamples(from startIndex: Int, upTo endIndex: Int) -> [Float] {
        pcmState.withLock { state in
            let bufStart = startIndex - state.trimOffset
            let bufEnd = min(endIndex - state.trimOffset, state.buffer.count)
            guard bufStart >= 0, bufEnd > bufStart else { return [] }
            return Array(state.buffer[bufStart..<bufEnd])
        }
    }

    /// Trim committed samples from the front of the PCM buffer to cap memory usage.
    /// `upTo` is an absolute sample index — samples before this index are freed.
    func trimSamples(upTo absoluteIndex: Int) {
        pcmState.withLock { state in
            let bufIndex = absoluteIndex - state.trimOffset
            guard bufIndex > 0 else { return }
            let trimCount = min(bufIndex, state.buffer.count)
            state.buffer.removeFirst(trimCount)
            state.trimOffset += trimCount
        }
    }

    /// Compute the RMS energy of a range of samples without copying the buffer.
    /// Used by the transcription loop to skip whisper inference on silence.
    func rmsEnergy(from startIndex: Int, count: Int) -> Float {
        pcmState.withLock { state in
            let bufStart = startIndex - state.trimOffset
            guard bufStart >= 0 else { return 0 }
            let bufEnd = min(bufStart + count, state.buffer.count)
            guard bufEnd > bufStart else { return 0 }
            var sumSquares: Float = 0
            for i in bufStart..<bufEnd {
                let s = state.buffer[i]
                sumSquares += s * s
            }
            return sqrt(sumSquares / Float(bufEnd - bufStart))
        }
    }

    /// 估计近期噪声底（自适应静音阈值用）：最近 windowSamples 内
    /// frameSamples 帧 RMS 的约 10 分位。返回 0 表示数据不足。
    /// 10 分位落在"最安静的 10% 帧"上——语音+停顿混合窗口中即为停顿/底噪水平。
    func estimateNoiseFloor(upTo endIndex: Int, frameSamples: Int, windowSamples: Int) -> Float {
        pcmState.withLock { state in
            let bufEnd = min(endIndex - state.trimOffset, state.buffer.count)
            let bufStart = max(0, bufEnd - windowSamples)
            guard frameSamples > 0, bufEnd - bufStart >= frameSamples * 3 else { return 0 }
            let frameCount = (bufEnd - bufStart) / frameSamples
            var values = [Float]()
            values.reserveCapacity(frameCount)
            for f in 0..<frameCount {
                let s = bufStart + f * frameSamples
                var sumSquares: Float = 0
                for i in s..<(s + frameSamples) {
                    let v = state.buffer[i]
                    sumSquares += v * v
                }
                values.append(sqrt(sumSquares / Float(frameSamples)))
            }
            values.sort()
            return values[max(0, values.count / 10)]
        }
    }

    /// 当前音频电平（最近 1 秒 RMS，供调试显示 Audio Level）。
    var currentAudioLevel: Float {
        pcmState.withLock { state in
            let count = min(state.buffer.count, 16000)
            guard count > 0 else { return 0 }
            var sum: Float = 0
            for s in state.buffer.suffix(count) {
                sum += s * s
            }
            return sqrt(sum / Float(count))
        }
    }

    /// 捕获源应用是否仍在运行（SCStream 音频源）。
    /// 用户关闭屏幕共享软件/退出应用时返回 false，用于自动结束录制。
    func isCaptureSourceRunning() -> Bool {
        guard let app = recordingApp else { return true }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
        let pid = app.processID
        if pid != 0 {
            return running.contains { $0.processIdentifier == pid }
        }
        return !running.isEmpty
    }

    /// Scan the absolute range `[searchFrom, searchTo)` in fixed `frameSamples`-sized frames and
    /// return the absolute sample index at the START of the rightmost silence run of at least
    /// `minSilenceFrames` frames, provided at least one speech frame precedes it. A frame is
    /// "silent" when its RMS is below `silenceThreshold`.
    ///
    /// Used to place live-transcription chunk cuts at natural pauses: cutting here lets the loop
    /// commit the completed utterance and hold back any trailing in-progress speech. Returns nil
    /// when no qualifying trailing silence exists (e.g. continuous speech). Computed under a single
    /// lock so it stays atomic with concurrent appends/trims.
    func lastSilenceCut(searchFrom: Int, searchTo: Int,
                        frameSamples: Int, silenceThreshold: Float, minSilenceFrames: Int) -> Int? {
        pcmState.withLock { state in
            let bufStart = max(0, searchFrom - state.trimOffset)
            let bufEnd = min(searchTo - state.trimOffset, state.buffer.count)
            guard frameSamples > 0, bufEnd - bufStart >= frameSamples else { return nil }

            // Per-frame silence flags over the search range.
            let frameCount = (bufEnd - bufStart) / frameSamples
            guard frameCount > 0 else { return nil }
            var isSilent = [Bool](repeating: false, count: frameCount)
            for f in 0..<frameCount {
                let s = bufStart + f * frameSamples
                let e = s + frameSamples
                let frame = state.buffer[s..<e]
                // VAD 联合判定：低能量（原语义）或高过零率（高频噪声）。
                isSilent[f] = VAD.isNonSpeech(
                    rms: VAD.rmsEnergy(frame),
                    zcr: VAD.zeroCrossingRate(frame),
                    silenceThreshold: silenceThreshold)
            }

            // Walk from the right: find the rightmost run of >= minSilenceFrames silent frames
            // whose start has at least one speech frame before it.
            var run = 0
            var f = frameCount - 1
            while f >= 0 {
                if isSilent[f] {
                    run += 1
                    if run >= minSilenceFrames {
                        let runStartFrame = f               // start of this silence run
                        let hasSpeechBefore = (0..<runStartFrame).contains { !isSilent[$0] }
                        guard hasSpeechBefore else { return nil }
                        return state.trimOffset + bufStart + runStartFrame * frameSamples
                    }
                } else {
                    run = 0
                }
                f -= 1
            }
            return nil
        }
    }

    /// 语音密度：区间内能量高于阈值的帧占比（0–1）。
    /// 噪声门用——整段密度 < 0.25（>75% 低置信块）时丢弃，不浪费 ASR 算力。
    func speechDensity(from startIndex: Int, to endIndex: Int,
                       frameSamples: Int, threshold: Float) -> Float {
        pcmState.withLock { state in
            let bufStart = max(0, startIndex - state.trimOffset)
            let bufEnd = min(endIndex - state.trimOffset, state.buffer.count)
            guard frameSamples > 0, bufEnd - bufStart >= frameSamples else { return 0 }
            let frameCount = (bufEnd - bufStart) / frameSamples
            guard frameCount > 0 else { return 0 }
            var speechFrames = 0
            for f in 0..<frameCount {
                let s = bufStart + f * frameSamples
                var sumSquares: Float = 0
                for i in s..<(s + frameSamples) {
                    let v = state.buffer[i]
                    sumSquares += v * v
                }
                // 与主循环封口判定同源的联合 VAD。
                let frame = state.buffer[s..<(s + frameSamples)]
                let isSpeech = !VAD.isNonSpeech(
                    rms: (sumSquares / Float(frameSamples)).squareRoot(),
                    zcr: VAD.zeroCrossingRate(frame),
                    silenceThreshold: threshold)
                if isSpeech { speechFrames += 1 }
            }
            return Float(speechFrames) / Float(frameCount)
        }
    }

    /// 最低能量切点（谷值回溯）：在区间后 70% 找帧 RMS 平滑（5 帧滑窗）
    /// 最低点，且谷值 < 段均值 80% 才有效（切在自然停顿而非词中间）。
    /// 返回绝对采样位置；无有效谷值返回 nil（调用方硬切兜底）。
    func lowestEnergyCut(searchFrom startIndex: Int, searchTo endIndex: Int,
                         frameSamples: Int) -> Int? {
        pcmState.withLock { state in
            let bufStart = max(0, startIndex - state.trimOffset)
            let bufEnd = min(endIndex - state.trimOffset, state.buffer.count)
            guard frameSamples > 0, bufEnd - bufStart >= frameSamples * 4 else { return nil }
            let frameCount = (bufEnd - bufStart) / frameSamples
            var frameRMS = [Float](repeating: 0, count: frameCount)
            var mean: Float = 0
            for f in 0..<frameCount {
                let s = bufStart + f * frameSamples
                var sumSquares: Float = 0
                for i in s..<(s + frameSamples) {
                    let v = state.buffer[i]
                    sumSquares += v * v
                }
                frameRMS[f] = (sumSquares / Float(frameSamples)).squareRoot()
                mean += frameRMS[f]
            }
            mean /= Float(frameCount)
            // 5 帧滑窗平滑（去单帧噪声）。
            let smoothed = (0..<frameCount).map { f -> Float in
                let lo = max(0, f - 2), hi = min(frameCount - 1, f + 2)
                var sum: Float = 0
                for i in lo...hi { sum += frameRMS[i] }
                return sum / Float(hi - lo + 1)
            }
            // 后 70% 区间找全局最低点（避免切得太靠前丢句首）。
            let searchLo = frameCount * 3 / 10
            var bestFrame = -1
            var bestRMS: Float = .greatestFiniteMagnitude
            for f in searchLo..<frameCount where smoothed[f] < bestRMS {
                bestRMS = smoothed[f]
                bestFrame = f
            }
            guard bestFrame >= 0, bestRMS < mean * 0.8 else { return nil }
            return state.trimOffset + bufStart + bestFrame * frameSamples
        }
    }

    /// Clears the accumulated PCM sample buffer (called when recording ends).
    private func clearPCMBuffer() {
        pcmState.withLock { state in
            state.buffer.removeAll()
            state.trimOffset = 0
        }
    }

    // MARK: - App List

    func loadAvailableApps() {
        state = .loading
        error = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let myBundleID = Bundle.main.bundleIdentifier ?? "com.whisperasr"
                let appsWithWindows = Set(content.windows.map { $0.owningApplication?.bundleIdentifier })
                let apps = content.applications
                    .filter {
                        $0.bundleIdentifier != myBundleID
                            && !$0.applicationName.isEmpty
                            && appsWithWindows.contains($0.bundleIdentifier)
                            && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
                    }
                    .sorted { ($0.applicationName) < ($1.applicationName) }

                await MainActor.run {
                    self.availableApps = apps
                    self.state = .ready
                }
            } catch {
                await MainActor.run {
                    if (error as NSError).code == -3801 || "\(error)".contains("denied") {
                        self.state = .permissionDenied
                    } else {
                        self.error = error.localizedDescription
                        self.state = .permissionDenied
                    }
                }
            }
        }
    }

    // MARK: - Start Recording

    private static let recentAppsKey = "recentRecordingApps"

    /// Bundle IDs of recently recorded apps, most recent first.
    var recentAppBundleIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentAppsKey) ?? []
    }

    private func saveRecentApp(bundleID: String) {
        var recent = recentAppBundleIDs
        recent.removeAll { $0 == bundleID }
        recent.insert(bundleID, at: 0)
        if recent.count > 10 { recent = Array(recent.prefix(10)) }
        UserDefaults.standard.set(recent, forKey: Self.recentAppsKey)
    }

    func startRecording(app: SCRunningApplication) {
        guard state == .ready else { return }
        saveRecentApp(bundleID: app.bundleIdentifier)

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    await MainActor.run {
                        self.error = "No display found"
                    }
                    return
                }

                // 屏幕录制授权前置检查：未授权时主动请求（触发系统弹窗；
                // 系统只弹一次，之后需经系统设置）。SCStream 在未授权时
                // 只会静默产出空音频——必须在启动前拦截。
                if !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                    await MainActor.run {
                        self.error = "需要屏幕录制权限：请允许授权或在系统设置 → 隐私与安全性 → 屏幕录制中添加 WhisperASR"
                    }
                    return
                }

                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.channelCount = 1
                config.sampleRate = 48000
                // Minimal video config (required but we don't need video)
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let fileURL = self.makeOutputURL(appName: app.applicationName)
                self.customRecordingName = nil

                let writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)

                self.assetWriter = writer
                self.assetWriterInput = input
                self.outputURL = fileURL
                self._hasReceivedSamples.withLock { $0 = false }
                self.clearPCMBuffer()

                self.recordingApp = app

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.whisperasr.audio-capture"))
                try await stream.startCapture()

                self.stream = stream
                self.recordingAppName = app.applicationName

                if self.includeMicrophone {
                    do {
                        try self.startMicrophoneCapture()
                    } catch {
                        print("[AudioRecorder] failed to start microphone: \(error)")
                        await MainActor.run {
                            self.error = "Microphone unavailable, recording app audio only"
                        }
                    }
                }

                await MainActor.run {
                    self.state = .recording
                    self.recordingDuration = 0
                    self.recordingStartTime = Date()
                    self.timer = Self.commonModeTimer(interval: 1.0) { [weak self] in
                        guard let self, let start = self.recordingStartTime else { return }
                        self.recordingDuration = Date().timeIntervalSince(start)
                    }
                    self.startMeetingMonitor(app: app)
                    self.startAudioWatchdog()
                }
            } catch {
                // Tear down whatever got as far as starting: cancel the writer,
                // delete the stray output file, and drop the half-built stream so
                // the next attempt starts from a clean slate.
                if let stream = self.stream {
                    try? await stream.stopCapture()
                    self.stream = nil
                }
                if let writer = self.assetWriter {
                    writer.cancelWriting()
                }
                self.assetWriter = nil
                self.assetWriterInput = nil
                if let url = self.outputURL {
                    try? FileManager.default.removeItem(at: url)
                    self.outputURL = nil
                }
                self.recordingApp = nil
                self.recordingAppName = nil
                await MainActor.run {
                    self.error = "Failed to start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Stop Recording

    func stopRecording() async -> URL? {
        await MainActor.run {
            state = .saving
            timer?.invalidate()
            timer = nil
            stopMeetingMonitor()
            stopAudioWatchdog()
        }

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        stopMicrophoneCapture()
        clearPCMBuffer()
        recordingApp = nil

        let received = _hasReceivedSamples.withLock { $0 }
        print("[AudioRecorder] stopRecording: hasReceivedSamples=\(received), writer=\(assetWriter != nil), input=\(assetWriterInput != nil)")

        guard let writer = assetWriter, let input = assetWriterInput else {
            assetWriter = nil
            assetWriterInput = nil
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            print("[AudioRecorder] stopRecording: no writer/input, returning nil")
            return nil
        }

        input.markAsFinished()
        await writer.finishWriting()

        print("[AudioRecorder] stopRecording: writer.status=\(writer.status.rawValue), error=\(String(describing: writer.error))")

        let url: URL?
        if writer.status == .completed, received {
            url = outputURL
        } else {
            url = nil
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        assetWriter = nil
        assetWriterInput = nil

        print("[AudioRecorder] stopRecording: returning url=\(String(describing: url))")
        return url
    }

    // MARK: - Cancel Recording

    func cancelRecording() {
        Task {
            if let stream {
                try? await stream.stopCapture()
                self.stream = nil
            }

            self.stopMicrophoneCapture()
            self.clearPCMBuffer()
            self.recordingApp = nil

            if let writer = assetWriter {
                writer.cancelWriting()
                if let url = outputURL {
                    try? FileManager.default.removeItem(at: url)
                }
                assetWriter = nil
                assetWriterInput = nil
            }

            await MainActor.run {
                state = .ready
                timer?.invalidate()
                timer = nil
                stopMeetingMonitor()
                stopAudioWatchdog()
                recordingDuration = 0
            }
        }
    }

    // MARK: - Microphone Capture

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Target format matching SCStream output: 48kHz mono Float32
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

        let needsConversion = hwFormat.sampleRate != 48000 || hwFormat.channelCount != 1
        var converter: AVAudioConverter?
        if needsConversion {
            converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            var samples: [Float]
            if let converter {
                let ratio = 48000.0 / hwFormat.sampleRate
                let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
                var error: NSError?
                var consumed = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil, converted.frameLength > 0,
                      let channelData = converted.floatChannelData?[0] else { return }
                samples = Array(UnsafeBufferPointer(start: channelData, count: Int(converted.frameLength)))
            } else {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            }

            let capturedSamples = samples
            self.micSampleBuffer.withLock { buf in
                buf.append(contentsOf: capturedSamples)
                // Cap buffer size to prevent unbounded growth
                if buf.count > Self.maxMicBufferSamples {
                    buf.removeFirst(buf.count - Self.maxMicBufferSamples)
                }
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        self.isMicActive = true
    }

    private func stopMicrophoneCapture() {
        guard isMicActive else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micSampleBuffer.withLock { $0.removeAll() }
        isMicActive = false
    }

    /// Creates a new CMSampleBuffer with mic audio mixed into the app audio.
    /// Returns nil if mixing is not needed or fails — caller should use the original buffer.
    private func mixedSampleBuffer(from original: CMSampleBuffer) -> CMSampleBuffer? {
        guard isMicActive else { return nil }
        guard let formatDesc = CMSampleBufferGetFormatDescription(original),
              let blockBuffer = CMSampleBufferGetDataBuffer(original) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return nil }

        // Copy original audio data
        let sampleCount = totalLength / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: sampleCount)
        memcpy(&floats, dataPointer, totalLength)

        // Read matching mic samples and mix
        let micSamples = micSampleBuffer.withLock { buf -> [Float] in
            let count = min(sampleCount, buf.count)
            let result = Array(buf.prefix(count))
            buf.removeFirst(count)
            return result
        }
        for i in 0..<micSamples.count {
            let mixed = floats[i] + micSamples[i]
            floats[i] = max(-1.0, min(1.0, mixed))
        }

        // Create new block buffer with mixed data
        var newBlockBuffer: CMBlockBuffer?
        var res = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &newBlockBuffer
        )
        guard res == kCMBlockBufferNoErr, let newBlockBuffer else { return nil }

        res = floats.withUnsafeBytes { rawBuf in
            CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: newBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: totalLength
            )
        }
        guard res == kCMBlockBufferNoErr else { return nil }

        // Create new sample buffer
        let numSamples = CMSampleBufferGetNumSamples(original)
        let pts = CMSampleBufferGetPresentationTimeStamp(original)

        var newSampleBuffer: CMSampleBuffer?
        res = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: newBlockBuffer,
            formatDescription: formatDesc,
            sampleCount: numSamples,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &newSampleBuffer
        )
        guard res == noErr else { return nil }

        return newSampleBuffer
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioRecorder] SCStream stopped with error: \(error)")
        // Attempt to restart the stream automatically
        restartStream()
    }

    // MARK: - Audio Watchdog

    /// A repeating main-run-loop timer scheduled in `.common` modes, so it keeps
    /// firing during modal sessions (e.g. the Zoom meeting-ended NSAlert) — the
    /// default mode pauses there, which froze the duration display and stall
    /// watchdog for as long as the alert stayed open.
    private static func commonModeTimer(interval: TimeInterval, _ fire: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func startAudioWatchdog() {
        lastAudioBufferTime.withLock { $0 = Date() }
        audioWatchdogTimer = Self.commonModeTimer(interval: 5.0) { [weak self] in
            self?.checkAudioStall()
        }
    }

    private func stopAudioWatchdog() {
        audioWatchdogTimer?.invalidate()
        audioWatchdogTimer = nil
    }

    private func checkAudioStall() {
        guard state == .recording, !isRestartingStream else { return }
        let lastTime = lastAudioBufferTime.withLock { $0 }
        let elapsed = Date().timeIntervalSince(lastTime)
        if elapsed > Self.audioStallThreshold {
            print("[AudioRecorder] audio stall detected: no buffers for \(String(format: "%.1f", elapsed))s, restarting stream")
            restartStream()
        }
    }

    private func restartStream() {
        guard state == .recording, !isRestartingStream else { return }
        isRestartingStream = true

        Task {
            // Stop the old stream
            if let oldStream = self.stream {
                try? await oldStream.stopCapture()
                self.stream = nil
            }

            // Rebuild a fresh SCStream with the same app
            guard let app = self.recordingApp else {
                isRestartingStream = false
                return
            }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    isRestartingStream = false
                    return
                }

                // 屏幕录制授权前置检查：未授权时主动请求（触发系统弹窗；
                // 系统只弹一次，之后需经系统设置）。SCStream 在未授权时
                // 只会静默产出空音频——必须在启动前拦截。
                if !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                    await MainActor.run {
                        self.error = "需要屏幕录制权限：请允许授权或在系统设置 → 隐私与安全性 → 屏幕录制中添加 WhisperASR"
                    }
                    return
                }

                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.channelCount = 1
                config.sampleRate = 48000
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let newStream = SCStream(filter: filter, configuration: config, delegate: self)
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.whisperasr.audio-capture"))
                try await newStream.startCapture()
                self.stream = newStream
                self.lastAudioBufferTime.withLock { $0 = Date() }

                print("[AudioRecorder] stream restarted successfully")
            } catch {
                print("[AudioRecorder] stream restart failed: \(error)")
            }

            isRestartingStream = false
        }
    }

    // MARK: - Zoom Meeting Monitor

    private func startMeetingMonitor(app: SCRunningApplication) {
        guard Self.zoomBundleIDs.contains(app.bundleIdentifier) else { return }
        recordingPID = app.processID
        meetingStarted = false
        meetingEnded = false

        meetingMonitorTimer = Self.commonModeTimer(interval: 10.0) { [weak self] in
            self?.checkZoomMeetingWindows()
        }
    }

    private func stopMeetingMonitor() {
        meetingMonitorTimer?.invalidate()
        meetingMonitorTimer = nil
        recordingPID = nil
        meetingStarted = false
    }

    private func checkZoomMeetingWindows() {
        guard let pid = recordingPID else { return }

        // Run the blocking ps check on a background thread to avoid stalling the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Check if Zoom's CptHost subprocess is running — it only exists during an active call.
            let hasMeeting = self.zoomHasActiveCall(parentPID: pid)

            DispatchQueue.main.async {
                if hasMeeting {
                    self.meetingStarted = true
                } else if self.meetingStarted {
                    self.meetingMonitorTimer?.invalidate()
                    self.meetingMonitorTimer = nil
                    self.meetingEnded = true
                    self.onMeetingEnded?()
                }
            }
        }
    }

    /// Returns true if Zoom's CptHost (call/meeting host) subprocess is running under the given parent PID.
    /// Uses Darwin syscalls instead of spawning a /bin/ps subprocess.
    private func zoomHasActiveCall(parentPID: pid_t) -> Bool {
        var childPIDs = [pid_t](repeating: 0, count: 128)
        let byteCount = proc_listchildpids(parentPID, &childPIDs,
            Int32(childPIDs.count * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return false }
        let childCount = Int(byteCount) / MemoryLayout<pid_t>.size
        for i in 0..<childCount {
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(childPIDs[i], &pathBuf, UInt32(MAXPATHLEN)) > 0 {
                if String(cString: pathBuf).contains("CptHost") { return true }
            }
        }
        return false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        // Track that we're still receiving audio (for stall detection)
        lastAudioBufferTime.withLock { $0 = Date() }

        // Use mixed buffer if mic is active, otherwise use original
        let bufferToWrite = mixedSampleBuffer(from: sampleBuffer) ?? sampleBuffer

        // Accumulate 16kHz PCM samples for live transcription
        accumulatePCMSamples(from: bufferToWrite)

        guard let input = assetWriterInput else {
            print("[AudioRecorder] stream callback: no assetWriterInput")
            return
        }
        guard input.isReadyForMoreMediaData else {
            print("[AudioRecorder] stream callback: input not ready")
            return
        }

        let success = input.append(bufferToWrite)
        if success {
            let wasFirst = _hasReceivedSamples.withLock { val -> Bool in
                let first = !val
                val = true
                return first
            }
            if wasFirst {
                print("[AudioRecorder] first audio sample appended, numSamples=\(bufferToWrite.numSamples)")
            }
        } else {
            print("[AudioRecorder] stream callback: append failed, writer.status=\(assetWriter?.status.rawValue ?? -1), error=\(String(describing: assetWriter?.error))")
        }
    }

    /// Extracts Float32 samples from a CMSampleBuffer (48kHz) and resamples to 16kHz
    /// via AVAudioConverter (applies anti-alias filter) for whisper.cpp.
    private func accumulatePCMSamples(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return }

        let sampleCount = totalLength / MemoryLayout<Float>.size
        guard sampleCount > 0, let converter = pcmResampler else { return }

        let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount)

        guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.pcmSourceFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let inputChannel = inputBuffer.floatChannelData?[0] else { return }
        memcpy(inputChannel, floatPtr, sampleCount * MemoryLayout<Float>.size)
        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)

        // 48000 / 16000 = 3; +1 guards against rounding on non-multiples of 3.
        let outputCapacity = AVAudioFrameCount(sampleCount / 3 + 1)
        guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.pcmTargetFormat, frameCapacity: outputCapacity) else { return }

        var convertError: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard convertError == nil, outputBuffer.frameLength > 0,
              let outputChannel = outputBuffer.floatChannelData?[0] else { return }

        let resampled = Array(UnsafeBufferPointer(start: outputChannel, count: Int(outputBuffer.frameLength)))
        pcmState.withLock { state in
            state.buffer.append(contentsOf: resampled)
        }
    }

    // MARK: - Output URL

    private func makeOutputURL(appName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport.appendingPathComponent("WhisperASR/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd HH'h'"
        let timestamp = df.string(from: Date())
        let baseName: String
        if let custom = customRecordingName, !custom.isEmpty {
            let sanitized = custom.replacingOccurrences(of: "/", with: "-")
            baseName = "\(timestamp) \(sanitized)"
        } else {
            let sanitized = appName.replacingOccurrences(of: "/", with: "-")
            baseName = "\(timestamp) \(sanitized)"
        }
        var url = recordingsDir.appendingPathComponent("\(baseName).m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsDir.appendingPathComponent("\(baseName) \(counter).m4a")
            counter += 1
        }
        return url
    }

    // MARK: - System Preferences

    func openSystemPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
