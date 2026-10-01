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
    /// 非权限类的失败（无显示器、SCShareableContent 内部错误等）。
    /// 此前这类错误被一并归为 `.permissionDenied`：UI 只显示"权限被拒绝"
    /// 并把用户引向系统设置，真实原因（如 `error.localizedDescription`）
    /// 被丢弃，用户按提示操作也修不好。
    case failed(String)
}

@Observable
class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var state: RecordingState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// 状态变更回调（菜单栏图标等外部观察者用）。
    /// 用回调而不是让 AudioRecorder 反向依赖 UI 单例。
    var onStateChange: ((RecordingState) -> Void)?
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
    /// 写入器与写入器输入：均跨线程共享（采集回调线程读，主线程置 nil），
    /// 统一经 LockedRef 加锁访问——见文件末容器说明。
    private let assetWriterBox = LockedRef<AVAssetWriter>()
    private var assetWriter: AVAssetWriter? {
        get { assetWriterBox.value }
        set { assetWriterBox.value = newValue }
    }
    /// 采集回调（capture queue）与主线程共享的写入器输入。
    /// 由 `LockedRef` 保护：主线程在 stopRecording 里置 nil，采集队列
    /// 同时读它 append——裸 var 是未同步访问（isStopping 只缩小窗口，
    /// 挡不住"已过守卫、正在读引用"的交错）。读取经锁取到一个强引用后
    /// 即安全（ARC 保活），写入同样持锁。
    /// 用专门的容器类而非 OSAllocatedUnfairLock<AVAssetWriterInput?>：
    /// 后者要求 Element: Sendable，而 AVAssetWriterInput 是 @_nonSendable。
    private let writerInputBox = LockedRef<AVAssetWriterInput>()
    private var assetWriterInput: AVAssetWriterInput? {
        get { writerInputBox.value }
        set { writerInputBox.value = newValue }
    }
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var recordingAppName: String?
    private var outputURL: URL?
    private var _hasReceivedSamples = OSAllocatedUnfairLock(initialState: false)
    /// 停止/取消期间置位：丢弃"在途"的采集回调，防止 `markAsFinished()`/`cancelWriting()`
    /// 之后仍向 assetWriterInput append（采集回调线程与主线程并发，会崩/写坏文件）。
    private var isStopping = OSAllocatedUnfairLock(initialState: false)
    private var meetingMonitorTimer: Timer?
    private var recordingPID: pid_t?
    private var meetingStarted = false

    // Stream watchdog: detect stalled audio delivery and restart
    private var lastAudioBufferTime = OSAllocatedUnfairLock(initialState: Date())
    private var audioWatchdogTimer: Timer?
    private var recordingApp: SCRunningApplication?
    /// 流重建互斥标志。此前是裸 `var` + 「先判后置」两步（check-then-set 非原子）：
    /// 采集 delegate 队列（didStopWithError）与主 runloop 的 5s 看门狗可能
    /// 同时通过守卫、各自 startCapture，后者覆盖 `self.stream` 留下孤儿流，
    /// 该流继续向同一 writer 追加音频。现改为锁内原子「占用」。
    private let restartState = OSAllocatedUnfairLock(initialState: false)

    /// 尝试占用重建权：已在重建中则返回 false（调用方直接放弃本轮）。
    private func beginStreamRestart() -> Bool {
        restartState.withLock { inProgress -> Bool in
            if inProgress { return false }
            inProgress = true
            return true
        }
    }

    private var isRestartingStream: Bool { restartState.withLock { $0 } }

    /// 采集回调的写入积压：input 未就绪（写入器短暂落后）时暂存，下个回调
    /// 补写。上限约 1s 音频（48kHz、10ms/块 → 100 块），超限才丢弃并计数。
    private var pendingWrites: [CMSampleBuffer] = []
    private let pendingWritesLock = NSLock()
    private static let maxPendingWrites = 100
    private let droppedWriteCount = OSAllocatedUnfairLock(initialState: 0)

    /// 丢弃积压（停止/取消录制时调用：writer 即将 finishWriting，
    /// 积压块已无意义，留着只会延长对象生命周期）。
    private func clearPendingWrites() {
        pendingWritesLock.withLock { pendingWrites.removeAll() }
    }
    /// 采集代次：录制会话每次开始/结束递增。restartStream 的异步重建任务
    /// 用它判断"我这次重建是否仍然属于当前会话"（见 restartStream 注释）。
    private let streamGeneration = OSAllocatedUnfairLock(initialState: 0)

    /// 代次是否仍为当前会话（会话未结束、也没有被更新的 restart 取代）。
    private func isStreamGenerationCurrent(_ generation: Int) -> Bool {
        streamGeneration.withLock { $0 == generation }
    }
    /// How long without audio before we consider the stream stalled (seconds).
    private static let audioStallThreshold: TimeInterval = 15

    // Microphone mixing
    private var audioEngine: AVAudioEngine?
    private var micSampleBuffer = OSAllocatedUnfairLock(initialState: [Float]())
    private var isMicActive = false
    private static let maxMicBufferSamples = 48000 * 5 // 5 seconds cap
    /// 溢出后保留的样本数（0.5s）：把麦克风/系统音频的错位钳在这个量级，
    /// 同时保住麦克风音轨连续（见回调内注释）。
    private static let micResyncSamples = 48000 / 2

    // Live transcription: accumulated 16kHz mono PCM samples.
    // Buffer + trimOffset are in a single lock so reads/writes are always atomic.
    // Uses an amortized compaction strategy:
    // - `headIndex`: points to the valid start of the active buffer window.
    // - `trimOffset`: absolute sample count before `buffer[0]`.
    // - Trimming simply advances `headIndex` (O(1)).
    // - Periodic bulk compaction drains discarded head samples only when
    //   the dead prefix exceeds 30s (480,000 samples) or exceeds half the buffer size.
    private struct PCMState {
        var buffer: [Float] = []
        var headIndex: Int = 0
        var trimOffset: Int = 0

        var count: Int {
            max(0, buffer.count - headIndex)
        }

        var absoluteCount: Int {
            trimOffset + buffer.count
        }

        var activeOffset: Int {
            trimOffset + headIndex
        }

        /// References a slice of samples in absolute range `[startIndex, endIndex)`.
        /// Zero-copy: returns an ArraySlice that borrows (retains) the buffer's
        /// storage, so floating-point math can run outside the lock without an
        /// intermediate Array construction. Safe: CoW keeps the borrowed storage
        /// alive even if the buffer is appended to / compacted concurrently.
        /// 注意：返回切片的下标继承 buffer 的绝对下标（lowerBound 未必为 0），
        /// 相对下标遍历须以 `slice.startIndex` 为基准。
        func slice(from startIndex: Int, upTo endIndex: Int) -> ArraySlice<Float> {
            let relativeStart = startIndex - activeOffset
            let relativeEnd = min(endIndex - activeOffset, count)
            guard relativeStart >= 0, relativeEnd > relativeStart else { return [] }
            let actualStart = headIndex + relativeStart
            let actualEnd = headIndex + relativeEnd
            return buffer[actualStart..<actualEnd]
        }

        func slice(from startIndex: Int) -> ArraySlice<Float> {
            let relativeStart = startIndex - activeOffset
            guard relativeStart >= 0, relativeStart < count else { return [] }
            let actualStart = headIndex + relativeStart
            return buffer[actualStart...]
        }

        mutating func trim(upTo absoluteIndex: Int) {
            let relativeCut = absoluteIndex - activeOffset
            guard relativeCut > 0 else { return }
            let trimCount = min(relativeCut, count)
            headIndex += trimCount

            // Bulk compaction threshold: 30s of discarded samples (480,000 floats @ 16kHz)
            // or discarded head is larger than half the allocated buffer and > 64,000 samples.
            if headIndex > 480_000 || (headIndex > 64_000 && headIndex >= buffer.count / 2) {
                compact()
            }
        }

        mutating func compact() {
            guard headIndex > 0 else { return }
            buffer.removeFirst(headIndex)
            trimOffset += headIndex
            headIndex = 0
        }

        mutating func append(contentsOf samples: some Sequence<Float>) {
            buffer.append(contentsOf: samples)
        }

        mutating func clear() {
            buffer.removeAll()
            headIndex = 0
            trimOffset = 0
        }
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
        pcmState.withLock { $0.absoluteCount }
    }

    private static let zoomBundleIDs: Set<String> = ["us.zoom.xos", "us.zoom.videomeeting"]

    // MARK: - Live Transcription PCM Access

    /// References all accumulated 16kHz PCM samples for live transcription
    /// (zero-copy slice over the locked buffer's storage).
    func getAccumulatedSamples() -> ArraySlice<Float> {
        pcmState.withLock { $0.slice(from: $0.activeOffset) }
    }

    /// References the samples from absolute `startIndex` onward.
    ///
    /// **独立存储**（不是零拷贝）：返回值是新建 Array 的切片，不借用锁内
    /// buffer 的存储。原因：调用方（实时识别循环）会跨 `await` 持有该切片
    /// （getSamples → transcribeChunk），而采集回调每 ~20ms 向 buffer append
    /// 一次——只要切片还引用着 buffer 的存储，每次 append 都会触发整段 CoW
    /// 复制（含已 trim 但未 compact 的 30s 死前缀，约 2.5MB/次、~100MB/s）。
    /// 改成取用时一次性复制：单次拷贝 ≤ 一个 chunk（通常 12KB~512KB），
    /// 生产者侧彻底不再复制。
    func getSamples(from startIndex: Int) -> ArraySlice<Float> {
        pcmState.withLock { Array($0.slice(from: startIndex))[...] }
    }

    /// References the samples in the absolute range `[startIndex, endIndex)`.
    /// 独立存储，理由同 `getSamples(from:)`。
    func getSamples(from startIndex: Int, upTo endIndex: Int) -> ArraySlice<Float> {
        pcmState.withLock { Array($0.slice(from: startIndex, upTo: endIndex))[...] }
    }

    /// Trim committed samples from the front of the PCM buffer to cap memory usage.
    /// `upTo` is an absolute sample index — samples before this index are freed (O(1) amortized).
    func trimSamples(upTo absoluteIndex: Int) {
        pcmState.withLock { $0.trim(upTo: absoluteIndex) }
    }

    /// Compute the RMS energy of a range of samples.
    /// Zero-copy: slice is borrowed under lock; floating-point math runs outside
    /// the lock over the ArraySlice (no Array construction in this path).
    func rmsEnergy(from startIndex: Int, count: Int) -> Float {
        let samples = pcmState.withLock { $0.slice(from: startIndex, upTo: startIndex + count) }
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for s in samples {
            sumSquares += s * s
        }
        return sqrt(sumSquares / Float(samples.count))
    }

    /// 估计近期噪声底（自适应静音阈值用）：最近 windowSamples 内
    /// frameSamples 帧 RMS 的约 10 分位。返回 0 表示数据不足。
    /// 锁内仅拷贝数据切片，数学计算与排序在锁外执行。
    func estimateNoiseFloor(upTo endIndex: Int, frameSamples: Int, windowSamples: Int) -> Float {
        guard frameSamples > 0 else { return 0 }
        let samples = pcmState.withLock { state -> ArraySlice<Float> in
            let start = max(state.activeOffset, endIndex - windowSamples)
            return state.slice(from: start, upTo: endIndex)
        }
        guard samples.count >= frameSamples * 3 else { return 0 }
        let frameCount = samples.count / frameSamples
        var values = [Float]()
        values.reserveCapacity(frameCount)
        // 切片下标继承 buffer 绝对下标：帧起点以 startIndex 为基准。
        let base = samples.startIndex
        for f in 0..<frameCount {
            let s = base + f * frameSamples
            var sumSquares: Float = 0
            for v in samples[s..<(s + frameSamples)] {
                sumSquares += v * v
            }
            values.append(sqrt(sumSquares / Float(frameSamples)))
        }
        values.sort()
        return values[max(0, values.count / 10)]
    }

    /// 当前音频电平（最近 1 秒 RMS，供调试显示 Audio Level）。
    var currentAudioLevel: Float {
        let samples = pcmState.withLock { state -> ArraySlice<Float> in
            let start = max(state.activeOffset, state.absoluteCount - 16000)
            return state.slice(from: start, upTo: state.absoluteCount)
        }
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        return sqrt(sum / Float(samples.count))
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
    /// `minSilenceFrames` frames, provided at least one speech frame precedes it.
    ///
    /// Slice extracted atomically under lock; frame VAD checks run outside lock.
    func lastSilenceCut(searchFrom: Int, searchTo: Int,
                        frameSamples: Int, silenceThreshold: Float, minSilenceFrames: Int) -> Int? {
        guard frameSamples > 0 else { return nil }
        let (samples, baseIndex) = pcmState.withLock { state -> (ArraySlice<Float>, Int) in
            let actualStart = max(state.activeOffset, searchFrom)
            let slice = state.slice(from: actualStart, upTo: searchTo)
            return (slice, actualStart)
        }
        guard samples.count >= frameSamples else { return nil }

        let frameCount = samples.count / frameSamples
        guard frameCount > 0 else { return nil }
        // 切片下标继承 buffer 绝对下标：帧区间以 startIndex 为基准。
        let base = samples.startIndex
        var isSilent = [Bool](repeating: false, count: frameCount)
        for f in 0..<frameCount {
            let s = base + f * frameSamples
            let e = s + frameSamples
            let frame = samples[s..<e]
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
                    return baseIndex + runStartFrame * frameSamples
                }
            } else {
                run = 0
            }
            f -= 1
        }
        return nil
    }

    /// 语音密度：区间内能量高于阈值的帧占比（0–1）。
    /// 噪声门用——整段密度 < 0.25（>75% 低置信块）时丢弃，不浪费 ASR 算力。
    /// 锁内切片，单次计算 RMS 与 ZCR 并在锁外执行。
    func speechDensity(from startIndex: Int, to endIndex: Int,
                       frameSamples: Int, threshold: Float) -> Float {
        guard frameSamples > 0 else { return 0 }
        let samples = pcmState.withLock { state -> ArraySlice<Float> in
            let start = max(state.activeOffset, startIndex)
            return state.slice(from: start, upTo: endIndex)
        }
        guard samples.count >= frameSamples else { return 0 }
        let frameCount = samples.count / frameSamples
        guard frameCount > 0 else { return 0 }
        // 切片下标继承 buffer 绝对下标：帧区间以 startIndex 为基准。
        let base = samples.startIndex
        var speechFrames = 0
        for f in 0..<frameCount {
            let s = base + f * frameSamples
            let frame = samples[s..<(s + frameSamples)]
            let isSpeech = !VAD.isNonSpeech(
                rms: VAD.rmsEnergy(frame),
                zcr: VAD.zeroCrossingRate(frame),
                silenceThreshold: threshold)
            if isSpeech { speechFrames += 1 }
        }
        return Float(speechFrames) / Float(frameCount)
    }

    /// 最低能量切点（谷值回溯）：在区间后 70% 找帧 RMS 平滑（5 帧滑窗）
    /// 最低点，且谷值 < 段均值 80% 才有效（切在自然停顿而非词中间）。
    /// 返回绝对采样位置；无有效谷值返回 nil（调用方硬切兜底）。
    func lowestEnergyCut(searchFrom startIndex: Int, searchTo endIndex: Int,
                         frameSamples: Int) -> Int? {
        guard frameSamples > 0 else { return nil }
        let (samples, baseIndex) = pcmState.withLock { state -> (ArraySlice<Float>, Int) in
            let actualStart = max(state.activeOffset, startIndex)
            let slice = state.slice(from: actualStart, upTo: endIndex)
            return (slice, actualStart)
        }
        guard samples.count >= frameSamples * 4 else { return nil }
        let frameCount = samples.count / frameSamples
        var frameRMS = [Float](repeating: 0, count: frameCount)
        var mean: Float = 0
        // 切片下标继承 buffer 绝对下标：帧区间以 startIndex 为基准。
        let base = samples.startIndex
        for f in 0..<frameCount {
            let s = base + f * frameSamples
            let frame = samples[s..<(s + frameSamples)]
            frameRMS[f] = VAD.rmsEnergy(frame)
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
        return baseIndex + bestFrame * frameSamples
    }

    /// Clears the accumulated PCM sample buffer (called when recording ends).
    private func clearPCMBuffer() {
        pcmState.withLock { $0.clear() }
        // 写入积压同属「本次会话的临时数据」：全部停止路径都会走到这里，
        // 集中清理避免遗漏（积压块持有 CMSampleBuffer，留着会延长生命周期）。
        clearPendingWrites()
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
                        // 非权限错误：保留真实文案并用独立状态，避免把用户
                        // 引向系统设置（那边改不动这个错）。
                        self.error = error.localizedDescription
                        self.state = .failed(error.localizedDescription)
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
                    // 防御兜底（正常路径已在录制入口拦截）：触发系统请求 +
                    // 悬浮授权窗 + 打开系统设置录屏面板。
                    await PermissionGuidePanelController.shared.authorizeForRecording()
                    await MainActor.run {
                        self.error = "需要屏幕录制权限：请在弹出的引导中完成授权后重试"
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
                self.isStopping.withLock { $0 = false }
                // 新会话：递增采集代次，让上一会话遗留的 restart 任务失效
                //（它若恢复执行会把孤儿流挂上来）。
                self.streamGeneration.withLock { $0 += 1 }
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
        // 先置停止标志：采集回调队列上在途的 buffer 立即被丢弃，
        // 不会在下面 markAsFinished 之后继续 append。
        isStopping.withLock { $0 = true }
        // 递增采集代次：在途的 restartStream 任务恢复后不再重建流
        //（否则会留下一个属于"已结束会话"的孤儿采集流）。
        streamGeneration.withLock { $0 += 1 }
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
        isStopping.withLock { $0 = true }
        // 同 stopRecording：作废在途的 restartStream 任务。
        streamGeneration.withLock { $0 += 1 }
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
                // 麦克风与系统音频是两条独立时钟，消费侧从**队首**取
                //（min(sampleCount, buf.count)），所以积压量 = 混入的麦克风
                // 音频滞后量。旧上限 5 秒意味着最坏情况把 5 秒前的声音混进
                // 当前系统音频（用户说话时听到的是几秒前的自己）。
                // 溢出时只保留最近 0.5 秒：既把滞后钳到 0.5s 以内，又保住
                // 麦克风音轨的连续性（清空会让麦克风出现一段静音）。
                if buf.count > Self.maxMicBufferSamples {
                    AppLogger.shared.log(
                        .asr,
                        "Mic buffer backlog \(buf.count) samples — trimming to \(Self.micResyncSamples) to bound A/V skew")
                    buf.removeFirst(buf.count - Self.micResyncSamples)
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
        guard state == .recording, beginStreamRestart() else { return }
        // 采集代次：restart 的 Task 会在多个 await 点挂起，期间用户可能已
        // stopRecording（停流 + writer 收尾）。没有代次校验时，Task 恢复后
        // 仍会 startCapture 并把新流挂到 self.stream —— 该"孤儿流"的回调会
        // 写进下一次录音的 writer（混入上一段应用的音频），且用户以为已停止
        // 的屏幕采集仍在运行。stopRecording/cancelRecording 会递增本值。
        let generation = streamGeneration.withLock { $0 }

        Task {
            // defer 统一复位：无论哪条退出路径（权限失败 / 设备缺失 / catch /
            // 正常完成）都保证 isRestartingStream 回到 false，
            // 避免状态锁死导致 checkAudioStall 看门狗永久失效。
            defer { restartState.withLock { $0 = false } }

            // Stop the old stream
            if let oldStream = self.stream {
                try? await oldStream.stopCapture()
                self.stream = nil
            }

            // 会话已结束（或有更新的 restart 接管）：不再重建。
            guard self.isStreamGenerationCurrent(generation) else {
                print("[AudioRecorder] restart aborted: session ended during restart")
                return
            }

            // Rebuild a fresh SCStream with the same app
            guard let app = self.recordingApp else {
                return
            }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    return
                }

                // 屏幕录制授权前置检查：未授权时主动请求（触发系统弹窗；
                // 系统只弹一次，之后需经系统设置）。SCStream 在未授权时
                // 只会静默产出空音频——必须在启动前拦截。
                if !CGPreflightScreenCaptureAccess() {
                    // 防御兜底（正常路径已在录制入口拦截）：触发系统请求 +
                    // 悬浮授权窗 + 打开系统设置录屏面板。
                    await PermissionGuidePanelController.shared.authorizeForRecording()
                    await MainActor.run {
                        self.error = "需要屏幕录制权限：请在弹出的引导中完成授权后重试"
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
                // startCapture 前最后一次校验（上面还有若干 await）。
                guard self.isStreamGenerationCurrent(generation) else {
                    print("[AudioRecorder] restart aborted before startCapture: session ended")
                    return
                }
                try await newStream.startCapture()
                // startCapture 成功后再次校验：若期间会话已结束，立刻停掉
                // 这个刚起来的流，避免留下孤儿采集。
                guard self.isStreamGenerationCurrent(generation) else {
                    try? await newStream.stopCapture()
                    print("[AudioRecorder] restart rolled back: session ended during startCapture")
                    return
                }
                self.stream = newStream
                self.lastAudioBufferTime.withLock { $0 = Date() }

                print("[AudioRecorder] stream restarted successfully")
            } catch {
                print("[AudioRecorder] stream restart failed: \(error)")
            }
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
        meetingEnded = false
    }

    private func checkZoomMeetingWindows() {
        guard let pid = recordingPID else { return }

        // Run the blocking ps check on a background thread to avoid stalling the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Check if Zoom's CptHost subprocess is running — it only exists during an active call.
            let hasMeeting = self.zoomHasActiveCall(parentPID: pid)

            DispatchQueue.main.async {
                // 在途回调可能在 stopMeetingMonitor()/stopRecording() 之后才回到
                // 主线程：此时录音已结束、recordingPID 已清空——若仍触发
                // onMeetingEnded，会为一台已经停掉的录音弹「会议已结束？」提示。
                guard self.recordingPID != nil, self.meetingMonitorTimer != nil else { return }
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
        // 停止/取消进行中：丢弃在途 buffer（不再触碰 writer，也不再累积 PCM）。
        guard !isStopping.withLock({ $0 }) else { return }
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
        appendAudio(bufferToWrite, to: input)
    }

    /// 写入音频块，input 未就绪时暂存并在后续回调补写。
    ///
    /// 此前是「不 ready 就直接 return」：该块**已经**进了 PCM 缓冲（实时字幕
    /// 有它），却没写进 m4a —— 播放存档音频时字幕与声音对不上，且丢块只在
    /// 日志里留一行。现在改为有界积压队列（约 1s 音频），把「写入器短暂落后」
    /// 与「真的丢数据」区分开；只有超过上限才丢弃并计数。
    private func appendAudio(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        // 取出积压（含本轮新块），按顺序尽量写入。
        var toWrite = pendingWritesLock.withLock { () -> [CMSampleBuffer] in
            let queued = pendingWrites
            pendingWrites.removeAll()
            return queued
        }
        toWrite.append(buffer)

        var remainder: ArraySlice<CMSampleBuffer> = []
        for index in toWrite.indices {
            guard input.isReadyForMoreMediaData else {
                remainder = toWrite[index...]
                break
            }
            let buf = toWrite[index]
            if input.append(buf) {
                let wasFirst = _hasReceivedSamples.withLock { val -> Bool in
                    let first = !val
                    val = true
                    return first
                }
                if wasFirst {
                    print("[AudioRecorder] first audio sample appended, numSamples=\(buf.numSamples)")
                }
            } else {
                print("[AudioRecorder] stream callback: append failed, writer.status=\(assetWriter?.status.rawValue ?? -1), error=\(String(describing: assetWriter?.error))")
            }
        }

        guard !remainder.isEmpty else { return }
        pendingWritesLock.withLock {
            pendingWrites.append(contentsOf: remainder)
            if pendingWrites.count > Self.maxPendingWrites {
                let drop = pendingWrites.count - Self.maxPendingWrites
                pendingWrites.removeFirst(drop)
                let total = droppedWriteCount.withLock { count -> Int in
                    count += drop
                    return count
                }
                print("[AudioRecorder] write backlog overflow: dropped \(drop) buffers (total \(total)) — archived audio will be shorter than the live transcript")
            }
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

        // 零拷贝喂入：UnsafeBufferPointer 直接追加进 PCM 缓冲，
        // 不经中间 Array 构造（P0：转录链路禁止 Array(...)）。
        let resampled = UnsafeBufferPointer(start: outputChannel, count: Int(outputBuffer.frameLength))
        pcmState.withLock { $0.append(contentsOf: resampled) }
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

// MARK: - 写入器引用容器（AudioRecorder 内部）

/// 跨线程共享 `AVAssetWriter` / `AVAssetWriterInput?` 的锁保护容器。
/// `OSAllocatedUnfairLock<T?>` 不可用：其 Element 需满足 Sendable，
/// 而 AVAssetWriter / AVAssetWriterInput 标注为 @_nonSendable（Swift 6 下为错误）。
/// 本容器只做「加锁读写一个引用」，不承诺 Element 的 Sendable 语义。
///
/// 为什么 `assetWriter` 也必须走本容器：采集回调线程读 `assetWriter?.status`
/// 打日志，而 stopRecording / 启动失败清理在主线程把它置 nil——此前只有
/// `assetWriterInput` 被保护，`assetWriter` 仍是裸 var，属未同步的跨线程读写。
private final class LockedRef<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
