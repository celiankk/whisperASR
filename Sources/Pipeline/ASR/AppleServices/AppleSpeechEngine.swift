import Foundation
import Speech
import AVFoundation

// MARK: - Apple Speech Engine（AppleSpeechEngine）
//
// macOS 26 最新 Speech Framework 流式识别引擎，
// 完全基于 SpeechAnalyzer + SpeechTranscriber + AnalysisContext：
//
//   AudioBuffer → SpeechAnalyzer（音频输入/生命周期/task）
//                    ↓
//   SpeechTranscriber（实时语音转文字：partial / final）
//                    ↓
//   AnalysisContext（当前语言 / 热词配置 / 会话状态）
//                    ↓
//   ASRResult（统一输出：text / language / timestamp / confidence / isFinal）
//
// 特性：
// - 持续流式会话：start() 创建，append() 喂音频，partial/final 经回调实时输出；
// - 生命周期：start / pause / resume / finish / stop（含 cancelAndFinishNow）；
// - 语言资源自动加载/下载（SpeechTranscriber.installedLocales + AssetInventory）；
// - 权限检查：Speech Recognition（麦克风由录制流程负责）；
// - AppleSpeechDebug：初始化时间 / 语言加载时间 / buffer 数 / 识别延迟 /
//   partial 次数 / final 次数 / 错误信息。
//
// 不使用 SFSpeechRecognizer（识别实现与其完全无关）。

@available(macOS 26, *)
final class AppleSpeechEngine: @unchecked Sendable {
    // MARK: - 状态

    private(set) var state: AppleSpeechEngineState = .idle {
        didSet { onStateChange?(state) }
    }

    /// 状态变更回调（Manager 转发设置页）。
    var onStateChange: ((AppleSpeechEngineState) -> Void)?

    // MARK: - 调试统计（AppleSpeechDebug）

    private(set) var stats = AppleSpeechDebug()

    // MARK: - 输出回调

    /// 识别结果回调（partial / final 均由 isFinal 区分）。
    var onResult: ((ASRResult) -> Void)?
    /// 当前累积文本（会话内；Manager 用它计算增量）。
    var onTextUpdate: ((String) -> Void)?

    // MARK: - 会话状态

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var inputFormat: AVAudioFormat?
    /// 会话级采样率转换器（16kHz natural → analyzer 最佳格式）。
    /// 必须跨 append 复用：每次新建会丢掉重采样滤波器历史，在每块边界
    /// 产生伪影，影响识别质量。nil 表示目标格式即 16kHz（直通，不转换）。
    private var audioConverter: AVAudioConverter?
    private let lock = NSLock()

    /// 会话是否运行中。
    var isRunning: Bool {
        lock.withLock { analyzer != nil }
    }

    /// 当前累积文本（锁保护；Manager 增量计算用）。
    private var currentText = ""
    var latestText: String {
        lock.withLock { currentText }
    }

    /// 文件转录用：会话内所有 final 结果（按时间聚合，避免只拿到最后一句）。
    private var finalResults: [ASRResult] = []
    /// 是否收集 finalResults（仅文件转录开启；实时会话避免长时间录音内存增长）。
    private var collectFinalResults = false

    /// 会话解析后的语言标识（如 "zh-CN"；统一 ASRResult.language 用）。
    private var currentLocaleIdentifier: String?
    var languageIdentifier: String? {
        lock.withLock { currentLocaleIdentifier }
    }

    /// 已消费文本（增量基线）：waitForTextGrowth 与它做共同前缀对齐。
    /// 引擎 partial 是整段累积文本，final 可能修正/缩短（如 "ta pop"→"pop"），
    /// 单纯"变长才增量"会在文本回退时永久卡死；按共同前缀取增量则
    /// 增长与修正都覆盖。
    private var consumedText = ""

    /// 会话内已喂入的音频总时长（秒，按实际送入 analyzer 的帧数累计）。
    /// 文件转录超时缩放用（流式分块喂入后调用方不再持有全量采样数）。
    func totalAudioDuration() -> Double {
        Double(lock.withLock { cumulativeSamples }) / 16000.0
    }

    /// 等待文本增长（增量模式）：返回自上次消费点之后的增量文本；超时返回 nil。
    /// 与当前累积文本做共同前缀对齐——文本变长（正常 partial）或变短
    /// （final 修正）都会输出新文本（修正时输出修正后的剩余部分）。
    ///
    /// 取消语义：任务被取消（停录 / 退出）时立即返回 nil。不能用
    /// `try? await Task.sleep`：取消后 sleep 立即抛 CancellationError 且
    /// try? 会吞掉它，循环退化成无挂起点的高频忙转（100% CPU 直至超时，
    /// 曾导致长录音退出时应用卡死）。
    func waitForTextGrowth(timeout: Double) async -> TranscriptionResult? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = lock.withLock { currentText }
            let consumed = lock.withLock { consumedText }
            if text != consumed {
                let common = Self.commonPrefixCount(text, consumed)
                let incremental = String(text.dropFirst(common))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !incremental.isEmpty {
                    lock.withLock { consumedText = text }
                    return TranscriptionResult(
                        text: incremental,
                        segments: [TranscriptionSegment(start: 0, end: nil, text: incremental)]
                    )
                }
                // 纯空白变化：推进基线继续等。
                lock.withLock { consumedText = text }
            }
            if Task.isCancelled { return nil }
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return nil
            }
        }
        return nil
    }

    /// 等待文件转录的全部 final 结果；结果流和分析任务结束后立即返回。
    /// 超时兜底返回已收集到的 final（可能不完整），完全无结果返回空数组。
    /// 任务取消（停录后退出 / 队列取消）时立即返回已收集结果——不能
    /// `try? await Task.sleep` 吞取消异常忙转（见 waitForTextGrowth）。
    func waitForFinalResults(timeout: Double) async -> [ASRResult] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let finished = lock.withLock { resultsStreamEnded && analyzerStreamEnded }
            if finished {
                return Self.sortedFinalResults(lock.withLock { finalResults })
            }
            if Task.isCancelled { break }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
        return Self.sortedFinalResults(lock.withLock { finalResults })
    }

    private static func sortedFinalResults(_ results: [ASRResult]) -> [ASRResult] {
        results.sorted { lhs, rhs in
            if lhs.timestamp.start == rhs.timestamp.start {
                return (lhs.timestamp.end ?? .greatestFiniteMagnitude)
                    < (rhs.timestamp.end ?? .greatestFiniteMagnitude)
            }
            return lhs.timestamp.start < rhs.timestamp.start
        }
    }

    private var lastAppendDate: Date?
    private var pendingLatency: TimeInterval = 0
    /// 会话内已喂入采样数（AnalyzerInput 累积时间戳用，锁保护）。
    private var cumulativeSamples: Int64 = 0
    /// 结果流 / 分析任务是否已结束（文件转录必须等两者都结束，
    /// 不能拿到第一个 final 就返回——后续句可能还没输出）。
    private var resultsStreamEnded = false
    private var analyzerStreamEnded = false

    // MARK: - 生命周期

    /// start()：创建 SpeechTranscriber + AnalysisContext + SpeechAnalyzer，
    /// 启动流式会话（语言资源缺失时自动下载）。
    func start(localeIdentifier: String,
               bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy = .bufferingNewest(12),
               collectFinalResults: Bool = false) async throws {
        let begin = Date()
        state = .initializing
        stats.lastError = nil
        lock.withLock {
            resultsStreamEnded = false
            analyzerStreamEnded = false
            currentText = ""
            finalResults = []
            self.collectFinalResults = collectFinalResults
            consumedText = ""
            cumulativeSamples = 0
            lastAppendDate = nil
            pendingLatency = 0
        }

        // 1. 权限：语音识别（麦克风由调用方/录制流程负责，此处也检查）。
        guard AppleSpeechPermission.isSpeechAuthorized else {
            state = .permissionDenied
            let err = AppleSpeechError.notAuthorized
            stats.lastError = err.localizedDescription
            throw err
        }

        // 2. 语言解析（SpeechTranscriber.supportedLocale(equivalentTo:)）。
        guard SpeechTranscriber.isAvailable else {
            state = .unavailable
            let err = AppleSpeechError.unavailable("SpeechTranscriber 不可用")
            stats.lastError = err.localizedDescription
            throw err
        }
        let locale = Locale(identifier: localeIdentifier)
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            state = .unavailable
            let err = AppleSpeechError.localeUnsupported(localeIdentifier)
            stats.lastError = err.localizedDescription
            throw err
        }

        // 3. 语言资源加载（已安装检查 + 缺失自动下载）。
        state = .loadingLanguage
        let languageBegin = Date()
        await ensureAssetInstalled(for: resolved)
        stats.languageLoadDuration = Date().timeIntervalSince(languageBegin)

        // 4. SpeechTranscriber（partial/final）。
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        // 5. AnalysisContext（当前语言 / 热词 / 会话配置）。
        let context = AnalysisContext()
        let keywords = ASRPromptManager.shared.contextualKeywords
        if !keywords.isEmpty {
            context.contextualStrings[.general] = keywords
        }

        // 6. SpeechAnalyzer（本地识别：on-device 能力检查）。
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyzer.setContext(context)
        let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 16000, channels: 1, interleaved: false)!
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: natural) ?? natural
        try await analyzer.prepareToAnalyze(in: format)

        // 7. 输入流 + 结果消费 + 分析启动。
        let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: bufferingPolicy) { continuation in
            self.lock.withLock { self.inputContinuation = continuation }
        }

        let resultsTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock { self.resultsStreamEnded = true }
            }
            do {
                for try await result in transcriber.results {
                    self.handleResult(result)
                }
                AppLogger.shared.log(.asr, "AppleSpeechEngine: results stream ended")
            } catch is CancellationError {
            } catch {
                self.stats.lastError = error.localizedDescription
                AppLogger.shared.log(.asr, "AppleSpeechEngine: results ERROR \(error.localizedDescription)")
            }
        }
        let analyzerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock { self.analyzerStreamEnded = true }
            }
            do {
                try await analyzer.start(inputSequence: inputStream)
                AppLogger.shared.log(.asr, "AppleSpeechEngine: analyzer stream ended")
            } catch is CancellationError {
            } catch {
                self.state = .error
                self.stats.lastError = error.localizedDescription
                AppLogger.shared.log(.asr, "AppleSpeechEngine: analyzer ERROR \(error.localizedDescription)")
            }
        }

        lock.withLock {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.resultsTask = resultsTask
            self.analyzerTask = analyzerTask
            self.inputFormat = format
            self.currentLocaleIdentifier = resolved.identifier
            self.audioConverter = Self.formatsMatch(natural, format)
                ? nil
                : AVAudioConverter(from: natural, to: format)
        }
        stats.initDuration = Date().timeIntervalSince(begin)
        state = .listening
        AppLogger.shared.log(.asr, "AppleSpeechEngine: started (\(resolved.identifier)) "
            + "init=\(AppleSpeechEngine.ms(stats.initDuration))ms "
            + "language=\(AppleSpeechEngine.ms(stats.languageLoadDuration))ms")
    }

    /// 喂入音频（16kHz mono Float32；实时分块持续调用）。
    /// 时间戳：会话内累积采样时间（所有块传 .zero 会让 analyzer 认为音频
    /// 在 0 时刻重叠，导致识别无结果）。
    func append(samples: [Float]) {
        guard isRunning, !samples.isEmpty else { return }
        lock.withLock {
            guard let continuation = inputContinuation, let format = inputFormat else { return }
            let source = Self.makePCMBuffer(samples)
            // 目标格式即 16kHz 时直通；否则用会话级共享转换器（保留重采样
            // 滤波器历史）。转换失败回落原始 buffer。
            let inputBuffer: AVAudioPCMBuffer
            if let converter = audioConverter {
                inputBuffer = Self.convertBuffer(source, with: converter) ?? source
            } else {
                inputBuffer = source
            }
            guard inputBuffer.frameLength > 0 else { return }
            let startTime = CMTime(value: cumulativeSamples,
                                   timescale: CMTimeScale(format.sampleRate))
            // 以实际送入 analyzer 的帧数推进时间戳；重采样到非 16kHz 时
            // 用 samples.count 会造成时间轴漂移。
            cumulativeSamples += Int64(inputBuffer.frameLength)
            continuation.yield(AnalyzerInput(buffer: inputBuffer, bufferStartTime: startTime))
            stats.bufferCount += 1
            lastAppendDate = Date()
        }
    }

    /// 结束输入（最终结果输出后会话完成）。
    func finish() {
        lock.withLock {
            inputContinuation?.finish()
            inputContinuation = nil
        }
    }

    /// stop()：释放会话与任务（官方建议 cancelAndFinishNow 正确终止分析会话）。
    /// cancelAndFinishNow 与 speech 进程（XPC）交互，服务无响应时可能长时间
    /// 不返回——3 秒超时竞速保证调用方（停录 / 退出 / unloadModel）必定离开，
    /// 残留的 teardown 任务在后台继续，不阻塞退出。
    func stop() async {
        finish()
        let analyzerToCancel = lock.withLock { () -> SpeechAnalyzer? in
            resultsTask?.cancel()
            resultsTask = nil
            analyzerTask?.cancel()
            analyzerTask = nil
            let analyzer = self.analyzer
            transcriber = nil
            self.analyzer = nil
            inputFormat = nil
            audioConverter = nil
            currentText = ""
            finalResults = []
            collectFinalResults = false
            currentLocaleIdentifier = nil
            consumedText = ""
            cumulativeSamples = 0
            resultsStreamEnded = false
            analyzerStreamEnded = false
            lastAppendDate = nil
            pendingLatency = 0
            return analyzer
        }
        if let analyzer = analyzerToCancel {
            let completed = await Self.awaitWithTimeout(seconds: 3) {
                await analyzer.cancelAndFinishNow()
            }
            if !completed {
                AppLogger.shared.log(.asr, "AppleSpeechEngine: cancelAndFinishNow timed out — "
                    + "engine released without clean teardown")
            }
        }
        state = .idle
        AppLogger.shared.log(.asr, "AppleSpeechEngine: stopped \(stats.summary)")
    }

    /// 有界等待一个可能挂起的 async 操作：完成返回 true，超时返回 false
    /// （操作任务继续在后台运行，不阻塞调用方）。用 AsyncStream 而非
    /// task group：group 退出前必须等所有子任务结束，无法隔离不可取消
    /// 的挂起操作（见 HANDOFF 坑 1）。
    private static func awaitWithTimeout(seconds: Double,
                                         _ operation: @escaping () async -> Void) async -> Bool {
        let stream = AsyncStream<Bool> { continuation in
            Task {
                await operation()
                continuation.yield(true)
                continuation.finish()
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                continuation.finish()
            }
        }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() == true
    }

    // MARK: - 结果处理

    private func handleResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.shared.log(.asr, "AppleSpeechEngine: result final=\(result.isFinal) "
            + "text=\(text.prefix(40).debugDescription)")
        var confidence: Float? = nil
        var total: Double = 0
        var count = 0
        for run in result.text.runs {
            if let c = run.transcriptionConfidence {
                total += c
                count += 1
            }
        }
        if count > 0 { confidence = Float(total / Double(count)) }

        lock.withLock {
            currentText = text
            if let last = lastAppendDate {
                pendingLatency = Date().timeIntervalSince(last)
            }
            if result.isFinal { stats.finalCount += 1 } else { stats.partialCount += 1 }
        }
        if result.isFinal {
            stats.recognitionLatency = pendingLatency
        }

        let asr = ASRResult(
            text: text,
            isFinal: result.isFinal,
            language: lock.withLock { currentLocaleIdentifier },
            confidence: confidence,
            timestamp: (result.range.start.seconds, result.range.end.seconds)
        )
        if result.isFinal {
            lock.withLock {
                guard collectFinalResults else { return }
                // final 可能按语音段多次返回：按 start 去重/替换，
                // 文件转录结束后聚合为完整字幕。
                if let index = finalResults.firstIndex(where: {
                    abs($0.timestamp.start - asr.timestamp.start) < 0.001
                }) {
                    finalResults[index] = asr
                } else {
                    finalResults.append(asr)
                }
            }
        }
        onResult?(asr)
        onTextUpdate?(text)
    }

    // MARK: - 语言资源

    private func ensureAssetInstalled(for locale: Locale) async {
        let installed = await Set(SpeechTranscriber.installedLocales.map(\.identifier))
        guard !installed.contains(locale.identifier) else { return }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        do {
            if let installer = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                AppLogger.shared.log(.asr, "AppleSpeechEngine: downloading language asset \(locale.identifier)")
                try await installer.downloadAndInstall()
                AppLogger.shared.log(.asr, "AppleSpeechEngine: language asset installed \(locale.identifier)")
            }
        } catch {
            stats.lastError = error.localizedDescription
            AppLogger.shared.log(.asr, "AppleSpeechEngine: language asset download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 音频工具

    /// 两个字符串的共同前缀字符数（增量对齐用）。
    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        for (ca, cb) in zip(a, b) {
            if ca != cb { break }
            count += 1
        }
        return count
    }

    private static func makePCMBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    /// 两个音频格式的关键参数是否一致（一致则无需采样率转换）。
    private static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.commonFormat == b.commonFormat
            && a.channelCount == b.channelCount && a.isInterleaved == b.isInterleaved
    }

    /// 用共享转换器做一次块转换（streaming 模式：converter 实例跨调用保留
    /// 重采样滤波器历史，块边界无伪影）。
    private static func convertBuffer(_ source: AVAudioPCMBuffer,
                                      with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(
                  pcmFormat: converter.outputFormat,
                  frameCapacity: AVAudioFrameCount(
                      Double(source.frameLength) * converter.outputFormat.sampleRate
                          / converter.inputFormat.sampleRate + 1)
              ) else { return nil }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        return out.frameLength > 0 ? out : nil
    }

    private static func ms(_ interval: TimeInterval) -> Int {
        Int(interval * 1000)
    }
}
