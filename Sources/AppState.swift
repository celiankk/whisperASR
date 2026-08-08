import Foundation
import AppKit
import Observation

@Observable
class AppState {
    /// 转录历史由 TranscriptionHistoryManager 统一持有（保存/删除/批量删除/
    /// 查询/上限裁剪）；items 为只读转发，任何增删必须走 history 管理器。
    let history = TranscriptionHistoryManager()
    var items: [TranscriptionItem] { history.items }
    var selectedItemID: UUID?

    /// 主窗口内嵌设置页开关：工具栏设置按钮在主窗口内部切换 SettingsView，
    /// 不新建窗口；再次点击返回主界面。
    var showingSettingsPage = false

    // Live transcription state
    var liveSegments: [TranscriptionSegment] = []
    var isLiveTranscribing = false
    var enableLiveTranscription = true

    // Inline error banners surfaced in the unified floating overlay. Nil when no error.
    var liveError: String?
    var liveTranslationError: String?

    /// A short-lived, auto-dismissing toast for translation errors in the main
    /// window (e.g. expired/invalid API key, failed API call). Deduplicated and
    /// rate-limited so a stream of identical failures can't spam the user.
    var transientToast: String?
    private var toastDismissTask: Task<Void, Never>?
    /// Monotonic-ish marker for the last toast shown, used to suppress repeats.
    private var lastToastText: String?

    // Live translation state (per-segment)
    var liveTranslatedSegments: [String] = []
    /// 翻译方式：不翻译 / 本地模型 / 在线 API。
    /// 统一状态管理：存储属性（@Observable 可跟踪），setTranslationMode 为唯一写入口，
    /// UserDefaults 只做持久化镜像。禁止 View 各自保存副本。
    private(set) var translationMode: TranslationMode = TranslationMode.current
    /// 是否开启实时翻译（由翻译方式派生，保持旧接口兼容）。
    var enableLiveTranslation: Bool { translationMode != .off }

    func setTranslationMode(_ mode: TranslationMode) {
        guard translationMode != mode else { return }
        translationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
    }
    /// User-controlled pause for live translation (e.g. the speaker switched to
    /// the listener's native language). Distinct from `translationAuthPaused`,
    /// which is an error-driven stop. While paused, no API calls are made; on
    /// resume, segments spoken during the pause are skipped so only new speech
    /// is translated.
    var liveTranslationPaused = false

    // 一体化字幕浮层（newdme.md）：字幕 + 工具栏 + 录制控制同在一个长条浮层。
    // 浮层启停由录制流程驱动（点击“开始录制”自动显示），这里只保留样式偏好，
    // 不再有“显示/隐藏”开关（调试菜单仅用于样式预览，不控制浮层启停）。
    private enum SubtitleOverlayKeys {
        static let sourceFontSize = "subtitleOverlaySourceFontSize"
        static let translationFontSize = "subtitleOverlayTranslationFontSize"
        static let borderOpacity = "subtitleOverlayBorderOpacity"
    }

    var subtitleOverlaySourceFontSize = AppState.storedDouble(SubtitleOverlayKeys.sourceFontSize, default: 32)
    var subtitleOverlayTranslationFontSize = AppState.storedDouble(SubtitleOverlayKeys.translationFontSize, default: 24)
    var subtitleOverlayBorderOpacity = AppState.storedDouble(SubtitleOverlayKeys.borderOpacity, default: 0.08)
    /// 字幕最大显示行数（1–3，默认 3）。超过时滚动显示，不省略内容。
    var maxSubtitleLines: Int = {
        let stored = UserDefaults.standard.object(forKey: "subtitleMaxLines") as? Int
        return min(max(stored ?? 3, 1), 3)
    }()
    /// 字幕水平对齐（"left" / "center"，默认居中；只影响文本对齐，不移动窗口）。
    var subtitleHorizontalAlignment: String = {
        UserDefaults.standard.string(forKey: "subtitleHorizontalAlignment") ?? "center"
    }()
    /// 字幕空闲自动清除延迟（秒，默认 3；3 秒无新 ASR 输入清空浮窗）。
    var subtitleClearDelay: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleClearDelay") as? NSNumber
        return min(max(stored?.doubleValue ?? 3, 1), 10)
    }()
    /// 句子端点：最短识别时长（秒，默认 1；讲话不足不显示，避免嗯/啊）。
    var subtitleMinSpeechDuration: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleMinSpeechDuration") as? NSNumber
        return min(max(stored?.doubleValue ?? 1, 0.5), 3)
    }()
    /// 句子端点：最长单句时长（秒，默认 5；超过强制截断换下一句）。
    var subtitleMaxSentenceDuration: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleMaxSentenceDuration") as? NSNumber
        return min(max(stored?.doubleValue ?? 5, 2), 15)
    }()
    /// 句子端点：停顿判定阈值（秒，默认 1；停顿超过即一句结束）。
    var subtitleSilencePause: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleSilencePause") as? NSNumber
        return min(max(stored?.doubleValue ?? 1, 0.5), 3)
    }()
    // MARK: 字幕容器（SubtitleContainerLayer）——与字体解耦

    var subtitleContainerWidth: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleFrameWidth") as? NSNumber
        return min(max(stored?.doubleValue ?? 800, 400), 4000)
    }()
    var subtitleContainerHeight: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleFrameHeight") as? NSNumber
        return min(max(stored?.doubleValue ?? 240, 100), 2160)
    }()
    var subtitleBackgroundOpacity: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleBackgroundOpacity") as? NSNumber
        return min(max(stored?.doubleValue ?? 0.34, 0.1), 0.8)
    }()
    // MARK: 字幕编辑边框（默认显示，可配置颜色/透明度；只影响视觉）

    var subtitleEditBorderVisible: Bool = {
        UserDefaults.standard.object(forKey: "subtitleEditBorderVisible") as? Bool ?? true
    }()
    var subtitleEditBorderColorHex: String = {
        UserDefaults.standard.string(forKey: "subtitleEditBorderColorHex") ?? "FFFFFF"
    }()
    var subtitleEditBorderOpacity: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleEditBorderOpacity") as? NSNumber
        return min(max(stored?.doubleValue ?? 0.8, 0), 1)
    }()
    // MARK: 字幕文字（SubtitleTextLayer）

    var subtitleFontWeight: String = {
        let stored = UserDefaults.standard.string(forKey: "subtitleFontWeight") ?? "medium"
        return ["regular", "medium", "bold"].contains(stored) ? stored : "medium"
    }()
    var subtitleLineSpacing: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleLineSpacing") as? NSNumber
        return min(max(stored?.doubleValue ?? 2, 0), 12)
    }()
    /// 本地翻译服务不可用（LM Studio 断开等）：自动降级为“仅识别模式”，
    /// 保留原文显示，不崩溃、不无限重试。
    private(set) var translationUnavailable = false
    /// Allow the floating overlay to auto-hide when the mouse stays outside it.
    var floatingOverlayAutoHide = UserDefaults.standard.bool(forKey: "floatingOverlayAutoHide")
    /// Live transcript display mode (only translation vs original + translation).
    var liveTranslationOnly = false
    /// Keep the recording window floating above other apps.
    var recordingAlwaysOnTop = false

    /// Read a Double from UserDefaults, falling back when the key is absent.
    private static func storedDouble(_ key: String, default defaultValue: Double) -> Double {
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.doubleValue
        }
        return defaultValue
    }

    private let service = TranscriptionService()
    private var isTranscribing = false
    private var liveTranscriptionTask: Task<Void, Never>?
    /// 文件转录队列任务句柄（shutdown 时统一取消，避免后台任务残留）。
    private var transcriptionQueueTask: Task<Void, Never>?
    /// 整段翻译任务句柄（shutdown 时统一取消）。
    private var translateItemTask: Task<Void, Never>?
    private var translationFailureCount = 0
    /// Set when translation is paused due to an auth error; cleared on next start.
    private var translationAuthPaused = false
    private var lastAutoSaveTime: Date = .distantPast
    /// 字幕引擎：统一生命周期 / 刷新节流 / 性能监控 / 日志 / 异常恢复。
    let subtitleEngine = SubtitleEngine.shared
    /// 每 5 秒一次的健康检查任务（资源快照 + 自动恢复）。
    private var healthCheckTask: Task<Void, Never>?
    /// 当前录制使用的音频源（自动恢复重启 ASR 会话时使用）。
    private weak var liveRecorder: AudioRecorder?

    /// Maximum chunk duration sent to whisper (30 seconds at 16kHz).
    /// Caps processing time so the loop never snowballs.
    private static let maxChunkSamples = 16000 * 30
    /// When speech runs continuously past this without a pause (8s at 16kHz), force a chunk cut at
    /// the live tail rather than waiting longer. Bounds per-pass re-transcription cost for
    /// continuous/noisy speech（背景音乐或底噪下干净停顿可能整段不出现——8s 上限保证
    /// 每轮重转录成本有界、字幕延迟可控）。Kept well under `maxChunkSamples`.
    private static let forceChunkSamples = 16000 * 8
    /// 实时显示分段上限：超过丢弃最旧（环形窗口），防止数小时录制内存无限增长。
    private static let maxLiveSegments = 100
    /// sealed 分段上限：只保留近期（用于 overlap/显示），旧段不再需要。
    private static let maxSealedSegments = 200

    init() {
        history.load()
        selectedItemID = items.first?.id
        // 统一错误管理：非致命错误（模型/API/网络/ASR）→ 分类日志 + toast，不退出。
        ErrorManager.shared.toastHandler = { [weak self] message in
            self?.showToast(message)
        }
        // Auto-resume any pending items restored from disk
        if items.contains(where: { $0.status == .pending }) {
            startNextTranscription()
        }
        // Share the single loaded model with the OpenAI-compatible API server and
        // start it if the user left it enabled.
        Task { @MainActor [service] in
            APIServer.shared.attach(service: service)
            if UserDefaults.standard.bool(forKey: APIServer.enabledKey) {
                APIServer.shared.start()
            }
        }
    }

    var selectedItem: TranscriptionItem? {
        items.first { $0.id == selectedItemID }
    }

    func addFile(url: URL) {
        guard !items.contains(where: { $0.fileURL == url }) else {
            selectedItemID = items.first { $0.fileURL == url }?.id
            return
        }

        let item = TranscriptionItem(fileURL: url)
        history.add(item)
        selectedItemID = item.id
        enqueueTranscription(for: item)
    }

    func retranscribe(_ item: TranscriptionItem) {
        item.segments = []
        item.fullText = ""
        item.progress = 0
        item.translatedSegments = []
        item.translationLanguage = nil
        enqueueTranscription(for: item)
    }

    func renameItem(_ item: TranscriptionItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Preserve the file extension
        let ext = item.fileURL.pathExtension
        let nameWithExt = trimmed.hasSuffix(".\(ext)") ? trimmed : "\(trimmed).\(ext)"

        // Rename the actual file on disk; only adopt the new URL if the move
        // succeeded (moveItem also fails when the destination already exists).
        // Items without an audio file (e.g. recovered transcripts) just get a
        // new display name.
        let newURL = item.fileURL.deletingLastPathComponent().appendingPathComponent(nameWithExt)
        if newURL != item.fileURL, FileManager.default.fileExists(atPath: item.fileURL.path) {
            do {
                try FileManager.default.moveItem(at: item.fileURL, to: newURL)
            } catch {
                Task { @MainActor in
                    self.showToast("Couldn't rename \"\(item.fileName)\": \(error.localizedDescription)")
                }
                return
            }
            item.fileURL = newURL
        }
        item.fileName = nameWithExt
        history.save(item)
    }

    /// Add a file with pre-existing live transcription results (skip re-transcription).
    @discardableResult
    func addFileWithLiveResults(url: URL, segments: [TranscriptionSegment], fullText: String,
                                translatedSegments: [String] = [], translationLanguage: String? = nil) -> TranscriptionItem {
        let item = TranscriptionItem(fileURL: url)
        item.segments = segments
        item.fullText = fullText
        item.translatedSegments = translatedSegments
        item.translationLanguage = translationLanguage
        item.status = .completed
        history.add(item)
        selectedItemID = item.id
        return item
    }

    /// Stop live transcription and the recorder, then file the finished recording.
    /// Shared by the Finish Recording button and the Zoom meeting-ended flow.
    /// If the audio file failed to save but live transcription produced a
    /// transcript, the transcript is kept as an audio-less item instead of
    /// being silently dropped with the recording.
    @MainActor
    func finishRecording(recorder: AudioRecorder) async {
        let segments = liveSegments
        let fullText = segments.map { $0.text }.joined()
        let translations = liveTranslatedSegments
        let lang: String? = !translations.isEmpty
            ? UserDefaults.standard.string(forKey: "targetLanguage") : nil
        let hadLiveResults = isLiveTranscribing && !segments.isEmpty

        stopLiveTranscription()
        let url = await recorder.stopRecording()

        if let url {
            // Live results from a dedicated (usually smaller/faster) live model
            // are a draft: send the saved recording through the normal pipeline
            // so the main model produces the final transcript. Only when live
            // ran on the same model are its results kept as final.
            let liveModelDiffers = !ModelManager.shared.liveFileName.isEmpty
                && ModelManager.shared.liveFileName != ModelManager.shared.selectedFileName
            if hadLiveResults && !liveModelDiffers {
                addFileWithLiveResults(url: url, segments: segments, fullText: fullText,
                                       translatedSegments: translations, translationLanguage: lang)
            } else {
                addFile(url: url)
            }
        } else if hadLiveResults {
            let item = addFileWithLiveResults(
                url: URL(fileURLWithPath: "/unsaved-recording-\(UUID().uuidString)"),
                segments: segments, fullText: fullText,
                translatedSegments: translations, translationLanguage: lang)
            item.fileName = "Recording \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)) (audio not saved)"
            history.save(item)
        }
        recorder.state = .idle
    }

    // MARK: - Translate Completed Transcription

    /// Show a transient, auto-dismissing toast. Repeats of the same message are
    /// ignored (the timer just restarts) so a continuously-failing translation
    /// queue surfaces the problem once rather than flickering on every retry.
    @MainActor
    func showToast(_ text: String, duration: Duration = .seconds(6)) {
        transientToast = text
        lastToastText = text
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if it's still the same message we scheduled.
                if self?.lastToastText == text { self?.transientToast = nil }
            }
        }
    }

    func translateItem(_ item: TranscriptionItem, targetLanguage: String) {
        guard !item.segments.isEmpty, !item.isTranslating else { return }
        item.isTranslating = true
        item.translatedSegments = Array(repeating: "", count: item.segments.count)
        item.translationLanguage = targetLanguage

        // @MainActor: `item` is observed by SwiftUI, so every mutation below must
        // land on the main actor; only the translation API calls suspend off it.
        translateItemTask?.cancel()
        translateItemTask = Task { @MainActor in
            let texts = item.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }

            let batchSize = 20
            var transientFailures = 0

            batchLoop: for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, texts.count)
                let batch = Array(texts[batchStart..<batchEnd])

                let contextStart = max(0, batchStart - 2)
                let contextPairs: [(original: String, translated: String)] = (contextStart..<batchStart).compactMap { i in
                    guard !texts[i].isEmpty, !item.translatedSegments[i].isEmpty else { return nil }
                    return (original: texts[i], translated: item.translatedSegments[i])
                }

                let provider = TranslationManager.provider(for: TranslationMode.current)
                do {
                    let translations = try await provider.translate(
                        segmentTexts: batch,
                        targetLanguage: targetLanguage,
                        previousTranslations: contextPairs
                    )
                    for (offset, translation) in translations.enumerated() {
                        item.translatedSegments[batchStart + offset] = translation
                    }
                } catch let err as TranslationError {
                    print("[Translation] batch error: \(err)")
                    switch err {
                    case .authFailed, .invalidEndpoint, .localModelNotDetected, .unavailable:
                        // Not retriable — stop hammering the API and report it once.
                        self.showToast(err.errorDescription ?? "Translation failed")
                        break batchLoop
                    default:
                        transientFailures += 1
                    }
                } catch {
                    print("[Translation] batch error: \(error)")
                    transientFailures += 1
                }
            }

            // Some batches failed transiently (network/server/rate-limit) but we
            // kept going; let the user know the result is incomplete.
            if transientFailures > 0 {
                self.showToast("Translation incomplete — \(transientFailures) section\(transientFailures == 1 ? "" : "s") couldn't be translated. Check your network or API settings.")
            }

            item.isTranslating = false
            history.save(item)
        }
    }

    func clearTranslation(_ item: TranscriptionItem) {
        item.translatedSegments = []
        item.translationLanguage = nil
        history.save(item)
    }

    /// 应用退出：取消全部后台任务（ASR / 翻译 / 健康检查 / toast / 转录队列），
    /// 释放模型与推理资源。任何一步失败都不影响退出流程。
    func shutdown() {
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        translateItemTask?.cancel()
        translateItemTask = nil
        transcriptionQueueTask?.cancel()
        transcriptionQueueTask = nil
        sentenceTranslationPending = 0
        subtitleEngine.stop()
        service.shutdown()
    }

    func removeItem(_ item: TranscriptionItem) {
        history.remove(item)
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
    }

    /// 批量删除：返回实际删除数量（进行中的转录自动跳过）。
    /// 录音文件移废纸篓（可恢复），导入文件只移除记录。
    @discardableResult
    func removeItems(ids: Set<UUID>) -> Int {
        let removed = history.remove(ids: ids)
        if let selected = selectedItemID,
           ids.contains(selected),
           !items.contains(where: { $0.id == selected }) {
            selectedItemID = items.first?.id
        }
        return removed
    }

    private func enqueueTranscription(for item: TranscriptionItem) {
        item.status = .pending
        if !isTranscribing {
            startNextTranscription()
        }
    }

    private func startNextTranscription() {
        guard let item = history.firstPending() else {
            isTranscribing = false
            return
        }
        isTranscribing = true
        item.status = .transcribing
        item.progress = 0
        item.transcriptionStartTime = Date()

        transcriptionQueueTask = Task.detached { [service, history] in
            do {
                let result = try await service.transcribe(fileURL: item.fileURL) { progress in
                    Task { @MainActor in
                        item.progress = progress
                    }
                }
                await MainActor.run {
                    item.segments = result.segments
                    item.fullText = result.text
                    item.status = .completed
                    history.save(item)
                }
            } catch {
                await MainActor.run {
                    item.status = .failed(error.localizedDescription)
                    history.save(item)
                }
            }
            await MainActor.run { [weak self] in
                self?.startNextTranscription()
            }
        }
    }

    // MARK: - Live Transcription During Recording

    /// Start periodic live transcription from the AudioRecorder's accumulated PCM buffer.
    func startLiveTranscription(recorder: AudioRecorder) {
        liveSegments = []
        liveError = nil
        liveTranslationError = nil
        translationFailureCount = 0
        translationAuthPaused = false
        liveTranslationPaused = false
        isLiveTranscribing = true
        subtitleEngine.start()
        SubtitleHistoryManager.shared.clear()
        liveRecorder = recorder
        startHealthCheck()
        AppLogger.shared.log(.asr, "Live transcription started")

        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }

            // Pre-load the model and wait for it — avoids model loading latency on first chunk.
            // Surface load failures so the user isn't stuck at a silent "Waiting for audio...".
            do {
                try await self.service.preloadLiveModel()
            } catch {
                ErrorManager.shared.report(
                    .model, error,
                    context: "preloadLiveModel",
                    userFacing: "Couldn't load transcription model: \(error.localizedDescription)"
                )
                await MainActor.run {
                    self.liveError = "Couldn't load transcription model: \(error.localizedDescription)"
                    self.isLiveTranscribing = false
                }
                return
            }
            guard !Task.isCancelled else { return }

            // Partial/final streaming model:
            //  - Every pass re-transcribes the unsealed *tail* and shows it immediately, so the
            //    in-progress sentence appears within ~1s (no waiting for a pause).
            //  - Segments before the last silence pause are *sealed* (final) — they stop changing
            //    and are never re-transcribed, which keeps boundaries clean and translation steady.
            var sealedSegments: [TranscriptionSegment] = []
            var sealedSampleCount = 0
            // Whether the seal boundary fell inside a pause (clean). A clean boundary needs no
            // left-context overlap; a forced mid-speech seal does, to avoid clipping the cut word.
            var sealedClean = true
            var consecutiveSilenceCount = 0
            var lastTranscribedTotal = 0
            // Silence-scan tuning (16kHz): 100ms frames; a run of >=3 (~300ms) counts as a pause.
            let frameSamples = 1600
            let minSilenceFrames = 3
            // 固定下限阈值：干净麦克风输入（底噪 RMS < 0.001）行为与之前一致。
            let baseSilenceThreshold: Float = 0.001
            let contextSamples = 16000   // 1s left-context, used only after a forced seal

            // The loop awaits each transcribeChunk before iterating, so passes never overlap.
            while !Task.isCancelled {
                let totalSamples = recorder.accumulatedSampleCount
                let tailCount = totalSamples - sealedSampleCount

                // Need >=0.5s of unsealed audio and >=0.3s of new audio since the last pass —
                // keeps the live tail fresh without re-transcribing identical audio in a tight loop.
                guard tailCount >= 8000, totalSamples - lastTranscribedTotal >= 4800 else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                // 自适应静音阈值：固定 0.001 对带底噪/背景音的音频（屏幕共享、视频）
                // 永远不触发干净停顿——最安静帧 RMS 都高于它，封口逻辑失效，
                // 每轮被迫重转录 12s 尾部 → 识别越来越慢。
                // 每轮按最近 10s 的噪声底（帧 RMS 10 分位）动态计算：
                //   跳过阈值 = 噪声底 ×1.2（只有真正的背景静默才跳过转录）；
                //   封口阈值 = 噪声底 ×2.0（停顿帧略高于底噪即可判定）。
                // 干净输入下噪声底 ≈0 → 两个阈值都回落到 0.001，行为不变。
                let noiseFloor = recorder.estimateNoiseFloor(
                    upTo: totalSamples, frameSamples: frameSamples, windowSamples: 16000 * 10)
                let skipThreshold = noiseFloor > 0
                    ? min(max(noiseFloor * 1.2, baseSilenceThreshold), 0.01)
                    : baseSilenceThreshold
                let sealSilenceThreshold = noiseFloor > 0
                    ? min(max(noiseFloor * 2.0, baseSilenceThreshold), 0.02)
                    : baseSilenceThreshold

                // If the whole unsealed tail is silence, seal forward and show only sealed text.
                let rms = recorder.rmsEnergy(from: sealedSampleCount, count: tailCount)
                guard rms > skipThreshold else {
                    sealedSampleCount = totalSamples
                    sealedClean = true
                    lastTranscribedTotal = totalSamples
                    recorder.trimSamples(upTo: max(0, sealedSampleCount - contextSamples))
                    consecutiveSilenceCount += 1
                    let snapshot = sealedSegments
                    await MainActor.run {
                        self.liveSegments = Array(snapshot.suffix(Self.maxLiveSegments))
                        self.throttledAutoSave()
                    }
                    try? await Task.sleep(for: .milliseconds(consecutiveSilenceCount >= 2 ? 1000 : 500))
                    continue
                }
                consecutiveSilenceCount = 0

                // Re-transcribe the unsealed tail for live display. After a clean (silence) seal the
                // boundary needs no overlap; after a forced seal, re-transcribe 1s of context and
                // dedup so the cut word isn't dropped.
                let useOverlap = !sealedClean
                var tailStart = useOverlap ? max(0, sealedSampleCount - contextSamples) : sealedSampleCount

                // Defensive: bound the tail to whisper's 30s window. Only reachable if a pass
                // stalled badly; surface it instead of silently mis-transcribing.
                if totalSamples - tailStart > Self.maxChunkSamples {
                    print("[AppState] live tail \(totalSamples - tailStart) samples exceeds maxChunkSamples — transcribing only the most recent (older audio skipped)")
                    await MainActor.run {
                        self.liveError = "Transcription is falling behind — some audio may be skipped."
                    }
                    tailStart = totalSamples - Self.maxChunkSamples
                }

                let chunk = recorder.getSamples(from: tailStart, upTo: totalSamples)
                guard !chunk.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                lastTranscribedTotal = totalSamples
                let timeOffset = Double(tailStart) / 16000.0

                // Cap the wait so a GPU/Metal hang doesn't deadlock the live loop.
                // Generous: 4× chunk duration, minimum 60s.
                let chunkSeconds = Double(chunk.count) / 16000.0
                let timeoutSeconds = max(60.0, chunkSeconds * 4.0)
                do {
                    let result = try await Self.withTimeout(seconds: timeoutSeconds) {
                        try await self.service.transcribeChunk(samples: chunk)
                    }

                    // Offset timestamps to match position in the full stream.
                    let tailSegments = result.segments.map { seg in
                        TranscriptionSegment(
                            start: seg.start + timeOffset,
                            end: seg.end.map { $0 + timeOffset },
                            text: seg.text
                        )
                    }

                    // Combine sealed (final) + freshly transcribed tail (interim) for display.
                    let tailStartTime = Double(tailStart) / 16000.0
                    let kept = sealedSegments.filter { $0.start < tailStartTime }
                    var combined = kept
                    for seg in tailSegments {
                        var text = seg.text
                        if useOverlap, let lastText = combined.last?.text {
                            text = Self.trimOverlap(previous: lastText, current: text)
                        }
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            combined.append(TranscriptionSegment(
                                start: seg.start, end: seg.end, text: text))
                        }
                    }

                    // Advance the seal: to a trailing pause (clean), or forced once the tail has
                    // grown past the cap without one. Everything before it becomes final.
                    let silenceCut = recorder.lastSilenceCut(
                        searchFrom: sealedSampleCount, searchTo: totalSamples,
                        frameSamples: frameSamples, silenceThreshold: sealSilenceThreshold,
                        minSilenceFrames: minSilenceFrames)
                    var newSeal = sealedSampleCount
                    var newSealClean = sealedClean
                    if let cut = silenceCut, cut - sealedSampleCount >= 8000 {
                        newSeal = cut; newSealClean = true
                    } else if tailCount >= Self.forceChunkSamples {
                        newSeal = totalSamples; newSealClean = false
                    }

                    if newSeal > sealedSampleCount {
                        let sealTime = Double(newSeal) / 16000.0
                        sealedSegments = combined.filter { $0.start < sealTime }
                        sealedSampleCount = newSeal
                        sealedClean = newSealClean
                        // Nothing behind a clean (silence) seal is needed again; keep 1s behind a
                        // forced seal for the next pass's overlap.
                        recorder.trimSamples(upTo: max(0, newSeal - (newSealClean ? 0 : contextSamples)))
                    }

                    // 环形窗口：只保留近期段，防止数小时运行内存无限增长。
                    if sealedSegments.count > Self.maxSealedSegments {
                        sealedSegments.removeFirst(sealedSegments.count - Self.maxSealedSegments)
                    }
                    let snapshot = Array(combined.suffix(Self.maxLiveSegments))
                    await MainActor.run {
                        self.liveSegments = snapshot
                        self.throttledAutoSave()
                    }
                    // 翻译不再按每个快照触发：由字幕层检测到“一句结束”后，
                    // 通过 translateSentence 整句单飞发送（见 Live Translation）。
                } catch is TimeoutError {
                    ErrorManager.shared.report(
                        .asr, context: "chunk timed out after \(timeoutSeconds)s"
                    )
                    await MainActor.run {
                        self.liveError = "Transcription is slow — the model or GPU may be stuck. Continuing with next chunk."
                    }
                } catch {
                    ErrorManager.shared.report(.asr, error, context: "live transcription chunk")
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Stop the live transcription timer. Called when recording ends.
    func stopLiveTranscription() {
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        // Free the dedicated live model (if one was loaded) — the final file
        // transcription uses the main model.
        service.unloadLiveModel()
        sentenceTranslationPending = 0
        healthCheckTask?.cancel()
        healthCheckTask = nil
        liveRecorder = nil
        subtitleEngine.stop()
        translationFailureCount = 0
        translationAuthPaused = false
        isLiveTranscribing = false
        liveError = nil
        liveTranslationError = nil
        // Clear live results (the final file transcription will replace them)
        liveSegments = []
        liveTranslatedSegments = []
        liveTranslationPaused = false
        removeLiveRecoveryFile()
        AppLogger.shared.log(.asr, "Live transcription stopped")
    }

    // MARK: - 健康检查与自动恢复

    /// 每 5 秒一次：资源快照；发现异常（内存持续增长/队列过长）自动恢复。
    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.isLiveTranscribing else { return }
                self.performHealthCheck()
            }
        }
    }

    @MainActor
    private func performHealthCheck() {
        // 屏幕共享/捕获源被关闭：自动结束录制并释放全部资源。
        if let recorder = liveRecorder,
           recorder.state == .recording,
           !recorder.isCaptureSourceRunning() {
            subtitleEngine.logger.log("Capture source stopped — auto ending recording")
            Task { await self.finishRecording(recorder: recorder) }
            return
        }

        let model = ModelManager.shared.liveFileName.isEmpty
            ? ModelManager.shared.selectedFileName
            : ModelManager.shared.liveFileName
        let anomaly = subtitleEngine.tick(
            asr: liveTranscriptionTask == nil ? 0 : 1,
            translationQueue: sentenceTranslationPending,
            subtitleBuffers: liveSegments.count + liveTranslatedSegments.count,
            model: model.isEmpty ? "none" : model
        )
        if anomaly {
            recoverFromAnomaly()
        }
    }

    /// 自动恢复：清理字幕缓存、取消旧任务、必要时重启 ASR 循环；不崩溃。
    @MainActor
    private func recoverFromAnomaly() {
        subtitleEngine.logger.log("Auto-recovery: cleaning caches and stale tasks")
        translationFailureCount = 0

        // 收紧环形窗口（正常路径已按上限裁剪，这里兜底）。
        let cap = Self.maxLiveSegments
        if liveSegments.count > cap { liveSegments = Array(liveSegments.suffix(cap)) }
        if liveTranslatedSegments.count > cap { liveTranslatedSegments = Array(liveTranslatedSegments.suffix(cap)) }

        // ASR 循环意外死亡时重启一次（由 isLiveTranscribing + 任务存在性保护，避免递归）。
        if liveTranscriptionTask == nil, isLiveTranscribing, let recorder = liveRecorder {
            subtitleEngine.logger.log("Auto-recovery: restarting ASR session")
            startLiveTranscription(recorder: recorder)
        }
        showToast("检测到资源异常，已自动清理并继续运行")
    }

    // MARK: - Floating Letter Overlay

    func setSubtitleOverlaySourceFontSize(_ value: Double) {
        subtitleOverlaySourceFontSize = value
        UserDefaults.standard.set(value, forKey: SubtitleOverlayKeys.sourceFontSize)
    }

    func setSubtitleOverlayTranslationFontSize(_ value: Double) {
        subtitleOverlayTranslationFontSize = value
        UserDefaults.standard.set(value, forKey: SubtitleOverlayKeys.translationFontSize)
    }

    func setSubtitleOverlayBorderOpacity(_ value: Double) {
        subtitleOverlayBorderOpacity = value
        UserDefaults.standard.set(value, forKey: SubtitleOverlayKeys.borderOpacity)
    }

    func setMaxSubtitleLines(_ lines: Int) {
        let clamped = min(max(lines, 1), 3)
        maxSubtitleLines = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleMaxLines")
    }

    func setSubtitleHorizontalAlignment(_ value: String) {
        let normalized = value == "left" ? "left" : "center"
        subtitleHorizontalAlignment = normalized
        UserDefaults.standard.set(normalized, forKey: "subtitleHorizontalAlignment")
    }

    func setSubtitleClearDelay(_ seconds: Double) {
        let clamped = min(max(seconds, 1), 10)
        subtitleClearDelay = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleClearDelay")
    }

    func setSubtitleMinSpeechDuration(_ seconds: Double) {
        let clamped = min(max(seconds, 0.5), 3)
        subtitleMinSpeechDuration = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleMinSpeechDuration")
    }

    func setSubtitleMaxSentenceDuration(_ seconds: Double) {
        let clamped = min(max(seconds, 2), 15)
        subtitleMaxSentenceDuration = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleMaxSentenceDuration")
    }

    func setSubtitleSilencePause(_ seconds: Double) {
        let clamped = min(max(seconds, 0.5), 3)
        subtitleSilencePause = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleSilencePause")
    }

    func setSubtitleContainerWidth(_ value: Double) {
        let clamped = min(max(value, 400), 4000)
        // 无变化直接返回：窗口移动也会触发容器同步，避免每次拖动都写盘 +
        // 触发 @Observable 变更（防 Window→状态→UI→Window 反馈环）。
        guard clamped != subtitleContainerWidth else { return }
        subtitleContainerWidth = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleFrameWidth")
    }

    func setSubtitleContainerHeight(_ value: Double) {
        let clamped = min(max(value, 100), 2160)
        guard clamped != subtitleContainerHeight else { return }
        subtitleContainerHeight = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleFrameHeight")
    }

    func setSubtitleBackgroundOpacity(_ value: Double) {
        let clamped = min(max(value, 0.1), 0.8)
        subtitleBackgroundOpacity = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleBackgroundOpacity")
    }

    func setSubtitleEditBorderVisible(_ visible: Bool) {
        subtitleEditBorderVisible = visible
        UserDefaults.standard.set(visible, forKey: "subtitleEditBorderVisible")
    }

    func setSubtitleEditBorderColorHex(_ hex: String) {
        subtitleEditBorderColorHex = hex
        UserDefaults.standard.set(hex, forKey: "subtitleEditBorderColorHex")
    }

    func setSubtitleEditBorderOpacity(_ opacity: Double) {
        let clamped = min(max(opacity, 0), 1)
        subtitleEditBorderOpacity = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleEditBorderOpacity")
    }

    func setSubtitleFontWeight(_ value: String) {
        subtitleFontWeight = ["regular", "medium", "bold"].contains(value) ? value : "medium"
        UserDefaults.standard.set(subtitleFontWeight, forKey: "subtitleFontWeight")
    }

    func setSubtitleLineSpacing(_ value: Double) {
        let clamped = min(max(value, 0), 12)
        subtitleLineSpacing = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleLineSpacing")
    }

    func setFloatingOverlayAutoHide(_ enabled: Bool) {
        floatingOverlayAutoHide = enabled
        UserDefaults.standard.set(enabled, forKey: "floatingOverlayAutoHide")
    }

    func setLiveTranslationOnly(_ onlyTranslation: Bool) {
        liveTranslationOnly = onlyTranslation
    }

    func setRecordingAlwaysOnTop(_ alwaysOnTop: Bool) {
        // 窗口层级由窗口层（FloatingLetterOverlayController）观察
        // recordingAlwaysOnTop 单向同步，状态层不再直接触碰 NSWindow。
        recordingAlwaysOnTop = alwaysOnTop
    }

    func resetFloatingOverlayPosition() {
        Task { @MainActor in
            FloatingLetterOverlayController.shared.resetPosition()
        }
    }

    /// Punctuation/whitespace whisper sprinkles at chunk edges; ignored when matching an overlap.
    private static let overlapTrimChars = CharacterSet(
        charactersIn: "，。、！？；：「」『』（）()【】［］…—~,.!?;:'\" \t\n")

    /// Trim the leading portion of `current` that duplicates the trailing portion of `previous`.
    /// Produced when a forced chunk re-transcribes the 1s context overlap. The match floor is a
    /// single character (Mandarin is dense — the previous 4-char floor missed most overlaps) and
    /// boundary punctuation/whitespace is stripped so a comma/period whisper added at the cut can't
    /// block the match.
    static func trimOverlap(previous: String, current: String) -> String {
        var source = previous.trimmingCharacters(in: .whitespaces)
        while let last = source.unicodeScalars.last, overlapTrimChars.contains(last) {
            source.unicodeScalars.removeLast()
        }
        var target = Substring(current.trimmingCharacters(in: .whitespaces))
        while let first = target.unicodeScalars.first, overlapTrimChars.contains(first) {
            target = target.dropFirst()
        }
        let maxCheck = min(source.count, target.count)
        guard maxCheck >= 1 else { return current }
        for len in stride(from: maxCheck, through: 1, by: -1) {
            if target.hasPrefix(String(source.suffix(len))) {
                return String(target.dropFirst(len))
            }
        }
        return current
    }

    // MARK: - Live Transcription Auto-Save (crash recovery)

    private static var liveRecoveryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("live_recovery.json")
    }

    private struct LiveRecoveryData: Codable {
        let segments: [TranscriptionSegment]
        let fullText: String
        let translatedSegments: [String]
        let translationLanguage: String?
        let savedAt: Date
    }

    /// Only auto-save at most every 15 seconds to avoid JSON serialization overhead.
    @MainActor
    private func throttledAutoSave() {
        let now = Date()
        guard now.timeIntervalSince(lastAutoSaveTime) >= 15 else { return }
        lastAutoSaveTime = now
        autoSaveLiveTranscription()
    }

    /// Persist current live transcription to a recovery file so data survives a hang or crash.
    @MainActor
    private func autoSaveLiveTranscription() {
        let segments = liveSegments
        let text = segments.map { $0.text }.joined()
        let translations = liveTranslatedSegments
        let lang: String? = !translations.isEmpty
            ? UserDefaults.standard.string(forKey: "targetLanguage") : nil

        // Write on a background queue to avoid blocking the main thread
        Task.detached(priority: .utility) {
            let data = LiveRecoveryData(
                segments: segments, fullText: text,
                translatedSegments: translations, translationLanguage: lang,
                savedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let json = try? encoder.encode(data) else { return }
            let url = AppState.liveRecoveryURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: url, options: .atomic)
        }
    }

    private func removeLiveRecoveryFile() {
        try? FileManager.default.removeItem(at: Self.liveRecoveryURL)
    }

    /// Check if there is a recoverable live transcription from a previous crash/hang.
    var hasLiveRecoveryData: Bool {
        FileManager.default.fileExists(atPath: Self.liveRecoveryURL.path)
    }

    /// Import recovered live transcription as a completed transcription item.
    func importRecoveredTranscription() {
        let url = Self.liveRecoveryURL
        guard let data = try? Data(contentsOf: url),
              let recovery = try? JSONDecoder().decode(LiveRecoveryData.self, from: data)
        else { return }
        let item = TranscriptionItem(
            fileURL: URL(fileURLWithPath: "/recovered-\(ISO8601DateFormatter().string(from: recovery.savedAt))"))
        item.segments = recovery.segments
        item.fullText = recovery.fullText
        item.translatedSegments = recovery.translatedSegments
        item.translationLanguage = recovery.translationLanguage
        item.status = .completed
        item.fileName = "Recovered \(DateFormatter.localizedString(from: recovery.savedAt, dateStyle: .short, timeStyle: .short))"
        history.add(item)
        selectedItemID = item.id
        removeLiveRecoveryFile()
    }

    // MARK: - Live Translation

    /// Pause or resume live translation on demand. While paused no API calls are
    /// made; on resume only newly completed sentences are translated.
    @MainActor
    func setLiveTranslationPaused(_ paused: Bool) {
        guard liveTranslationPaused != paused else { return }
        liveTranslationPaused = paused
        if paused {
            // 暂停：立即取消排队/进行中的整句翻译，不再发新请求。
            sentenceTranslationPending = 0
        }
    }

    /// 整句翻译（字幕层检测到一句结束后调用，一次一句、单飞）：
    /// 所有语言统一进入 TranslationProvider；失败返回 nil（显示原文），
    /// 连续失败 3 次自动降级为“仅识别模式”。
    @MainActor
    func translateSentence(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard translationMode != .off, !liveTranslationPaused, !translationAuthPaused else {
            return nil
        }
        let targetLang = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
        guard !targetLang.isEmpty else { return nil }

        let provider = TranslationManager.provider(for: translationMode)
        do {
            let result = try await provider.translate(
                segmentTexts: [trimmed],
                targetLanguage: targetLang,
                previousTranslations: []
            )
            translationFailureCount = 0
            translationUnavailable = false
            return result.first
        } catch is CancellationError {
            // 取消（超时兜底 / 暂停 / 停止）不是服务故障：不计入三连失败。
            return nil
        } catch {
            ErrorManager.shared.report(.api, error, context: "translateSentence")
            translationFailureCount += 1
            if translationFailureCount >= 3 {
                translationUnavailable = true
                translationAuthPaused = true
                showToast("本地翻译服务不可用，已切换到仅识别模式")
            }
            return nil
        }
    }

    // MARK: - 整句翻译队列（TranslationQueue）

    /// 在途句数，超上限丢弃最新（显示原文兜底）。
    /// 有界并发：每句独立请求（本地/在线服务自带队列与重试），不做串行链——
    /// 串行会让后到的译文错过字幕状态机窗口被丢弃，且体感翻译明显变慢。
    private(set) var sentenceTranslationPending = 0
    private static let maxPendingSentenceTranslations = 8

    /// 整句翻译统一入口（桥接层调用）：有界并发 + 10s 超时兜底 + 队列上限。
    /// 历史记录（时间/原文/翻译/语言）在此单一收口。
    @MainActor
    func requestSentenceTranslation(_ text: String) async -> String? {
        guard sentenceTranslationPending < Self.maxPendingSentenceTranslations else {
            AppLogger.shared.log(.translation, "Sentence queue full, drop: \(text.prefix(24))…")
            SubtitleHistoryManager.shared.record(
                original: text, translation: nil, language: LanguageDetector.detect(text).rawValue
            )
            return nil
        }
        sentenceTranslationPending += 1
        defer { sentenceTranslationPending -= 1 }
        let result: String?
        do {
            result = try await Self.withTimeout(seconds: 10) {
                await self.translateSentence(text)
            }
        } catch is CancellationError {
            result = nil
        } catch {
            // 超时 = 服务慢（≠ 服务不可用）：只记日志，不计入三连失败降级。
            ErrorManager.shared.report(.network, error, context: "sentence translation timeout")
            result = nil
        }
        // 历史记录独立存储（容量上限 200），与实时字幕状态分离。
        SubtitleHistoryManager.shared.record(
            original: text, translation: result, language: LanguageDetector.detect(text).rawValue
        )
        return result
    }

    // MARK: - Timeout helper

    private struct TimeoutError: Error {}

    /// Run `operation` with a timeout. If it doesn't complete within `seconds`, throws TimeoutError.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
