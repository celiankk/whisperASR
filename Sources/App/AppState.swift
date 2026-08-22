import Foundation
import AppKit
import Observation

// MARK: - 全局状态（AppState）
//
// AppState 拆分后只保留三类职责：
// 1. 页面状态（历史列表、选中项、设置页开关）；
// 2. 全局配置引用（字幕样式、浮层偏好——UI 绑定兼容）；
// 3. 用户界面状态（liveSegments / liveError / toast / 翻译暂停等）。
//
// 业务逻辑已拆分到运行调度中心（AppRuntimeManager）：
//   ├── ASRManager（识别循环 / 健康检查 / 自动保存）
//   ├── TranslationManager（翻译队列 / Provider 调用 / API 请求管理）
//   └── SubtitleManager（partial/final 字幕 / 字幕缓存 / 生命周期）
//
// 禁止 AppState 直接处理：识别循环、翻译请求、API 调用、模型加载。
// 所有对外方法签名保持不变（FloatingLetter / Sidebar / ContentView 等
// UI 层绑定完全兼容）。

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
    /// 「录制后生成转录记录」开关（持久化）：只影响录制结束是否生成
    /// 历史条目/保留音频；实时字幕与翻译始终进行。
    var enableLiveTranscription: Bool {
        get { UserDefaults.standard.object(forKey: "enableTranscriptRecord") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enableTranscriptRecord") }
    }

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
        // 记录最近一次「非关闭」的翻译方式：选择 App 页「翻译」开关关闭
        // 只是临时切到 .off，重新打开时恢复用户配置的方式
        //（Apple / 本地 / 在线），不再被硬编码覆盖。
        if mode != .off {
            UserDefaults.standard.set(mode.rawValue, forKey: "lastActiveTranslationMode")
        }
        translationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
    }
    /// User-controlled pause for live translation (e.g. the speaker switched to
    /// the listener's native language). Distinct from `translationAuthPaused`,
    /// which is an error-driven stop. While paused, no API calls are made; on
    /// resume, segments spoken during the pause are skipped so only new speech
    /// is translated.
    var liveTranslationPaused = false
    /// 翻译服务不可用（3 连败自动降级为“仅识别模式”）；字幕层据此显示状态。
    private(set) var translationUnavailable = false

    /// 由 TranslationManager 回写降级状态（3 连败 → 仅识别模式）。
    func setTranslationUnavailable(_ unavailable: Bool) {
        translationUnavailable = unavailable
    }

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

    var maxSubtitleLines: Int = {
        let stored = UserDefaults.standard.object(forKey: "subtitleMaxLines") as? Int
        return stored ?? 2
    }()

    var subtitleHorizontalAlignment: String = {
        let stored = UserDefaults.standard.object(forKey: "subtitleHorizontalAlignment") as? String
        return stored ?? "left"
    }()

    var subtitleClearDelay: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleClearDelay") as? NSNumber
        return stored?.doubleValue ?? 3
    }()

    var subtitleContainerWidth: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleFrameWidth") as? NSNumber
        return stored?.doubleValue ?? 800
    }()

    var subtitleContainerHeight: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleFrameHeight") as? NSNumber
        return stored?.doubleValue ?? 200
    }()

    var subtitleBackgroundOpacity: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleBackgroundOpacity") as? NSNumber
        return stored?.doubleValue ?? 0.4
    }()

    var subtitleEditBorderVisible: Bool = {
        let stored = UserDefaults.standard.object(forKey: "subtitleEditBorderVisible") as? NSNumber
        return stored?.boolValue ?? true
    }()

    var subtitleEditBorderColorHex: String = {
        let stored = UserDefaults.standard.string(forKey: "subtitleEditBorderColorHex")
        return stored ?? "FFFFFF"
    }()

    var subtitleEditBorderOpacity: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleEditBorderOpacity") as? NSNumber
        return stored?.doubleValue ?? 0.6
    }()

    var subtitleFontWeight: String = {
        let stored = UserDefaults.standard.string(forKey: "subtitleFontWeight")
        return stored ?? "medium"
    }()

    var subtitleLineSpacing: Double = {
        let stored = UserDefaults.standard.object(forKey: "subtitleLineSpacing") as? NSNumber
        return stored?.doubleValue ?? 0
    }()

    var floatingOverlayAutoHide = UserDefaults.standard.bool(forKey: "floatingOverlayAutoHide")
    var liveTranslationOnly = false
    var recordingAlwaysOnTop = false

    /// Read a Double from UserDefaults, falling back when the key is absent.
    private static func storedDouble(_ key: String, default defaultValue: Double) -> Double {
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.doubleValue
        }
        return defaultValue
    }

    /// 运行调度中心：识别 / 翻译 / 字幕 / 模型生命周期统一编排。
    let runtime = AppRuntimeManager()
    /// 字幕引擎（生命周期门面）：UI 层（FloatingLetter 状态栏）读取监控。
    let subtitleEngine = SubtitleEngine.shared

    /// 文件转录队列任务句柄（shutdown 时统一取消，避免后台任务残留）。
    private var transcriptionQueueTask: Task<Void, Never>?
    var isTranscribing = false

    init() {
        history.load()
        selectedItemID = items.first?.id
        // 统一错误管理：非致命错误（模型/API/网络/ASR）→ 分类日志 + toast，不退出。
        ErrorManager.shared.toastHandler = { [weak self] message in
            self?.showToast(message)
        }
        // 注入运行调度中心（各管理器弱引用回写 UI 状态；含 APIServer attach）。
        runtime.attach(appState: self)
        // Auto-resume any pending items restored from disk
        if items.contains(where: { $0.status == .pending }) {
            startNextTranscription()
        }
    }

    var selectedItem: TranscriptionItem? {
        items.first { $0.id == selectedItemID }
    }

    // MARK: - 文件操作（页面状态）

    func addFile(url: URL) {
        let item = TranscriptionItem(fileURL: url)
        history.add(item)
        selectedItemID = item.id
        enqueueTranscription(for: item)
    }

    func retranscribe(_ item: TranscriptionItem) {
        item.status = .pending
        item.segments = []
        item.fullText = ""
        item.translatedSegments = []
        item.translationLanguage = nil
        history.save(item)
        enqueueTranscription(for: item)
    }

    func renameItem(_ item: TranscriptionItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ext = item.fileURL.pathExtension
        let nameWithExt = trimmed.hasSuffix(".\(ext)") ? trimmed : "\(trimmed).\(ext)"
        let newURL = item.fileURL.deletingLastPathComponent().appendingPathComponent(nameWithExt)
        do {
            try FileManager.default.moveItem(at: item.fileURL, to: newURL)
            item.fileURL = newURL
            item.fileName = nameWithExt
            history.save(item)
        } catch {
            Task { @MainActor in
                self.showToast("重命名失败：\(error.localizedDescription)")
            }
        }
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

        // 「转录记录」关闭：不生成转录历史条目，录音文件一并清理
        // （本模式为纯实时字幕用途；实时字幕/翻译已照常完成）。
        guard enableLiveTranscription else {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            recorder.state = .idle
            return
        }

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

    // MARK: - Toast

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

    // MARK: - 翻译（委托 TranslationManager）

    /// 整段批量翻译（页面操作）：批次循环在 TranslationManager。
    @MainActor
    func translateItem(_ item: TranscriptionItem, targetLanguage: String) {
        item.hydrateTranscriptIfNeeded()   // 懒加载条目翻译前载入完整内容
        runtime.translation.translate(item: item, targetLanguage: targetLanguage)
    }

    func clearTranslation(_ item: TranscriptionItem) {
        item.translatedSegments = []
        item.translationLanguage = nil
        history.save(item)
    }

    /// 整句翻译（字幕层检测到一句结束后调用，一次一句、单飞）：
    /// 所有语言统一进入 TranslationProvider；失败返回 nil（显示原文），
    /// 连续失败 3 次自动降级为“仅识别模式”。逻辑在 TranslationManager。
    @MainActor
    func translateSentence(_ text: String) async -> String? {
        await runtime.translation.translateSentence(text)
    }

    /// 整句翻译统一入口（桥接层调用）：有界并发 + 10s 超时兜底 + 队列上限。
    /// 历史记录在此单一收口。逻辑在 TranslationManager。
    @MainActor
    func requestSentenceTranslation(_ text: String) async -> String? {
        await runtime.translation.requestSentenceTranslation(text)
    }

    /// 流式整句翻译（桥接层调用）：逐 token 经 delta 回调上屏；
    /// 完成后历史记录收口。
    @MainActor
    func requestSentenceTranslationStreaming(_ text: String) async -> String? {
        guard runtime.translation.sentenceTranslationPending
            < TranslationManager.maxPendingSentenceTranslationsPublic else { return nil }
        let result = await runtime.translation.translateSentenceStreaming(text) { _ in }
        SubtitleHistoryManager.shared.record(
            original: text, translation: result,
            language: LanguageDetector.detect(text).rawValue)
        return result
    }

    /// Pause or resume live translation on demand. While paused no API calls are
    /// made; on resume only newly completed sentences are translated.
    @MainActor
    func setLiveTranslationPaused(_ paused: Bool) {
        guard liveTranslationPaused != paused else { return }
        liveTranslationPaused = paused
        if paused {
            // 暂停：立即取消排队/进行中的整句翻译，不再发新请求。
            runtime.translation.resetPending()
        }
    }

    // MARK: - 实时转录（委托 ASRManager）

    /// Start periodic live transcription from the AudioRecorder's accumulated PCM buffer.
    /// 实时循环 / 健康检查 / 自动保存在 ASRManager。
    func startLiveTranscription(recorder: AudioRecorder) {
        runtime.startLive(recorder: recorder)
    }

    /// Stop the live transcription timer. Called when recording ends.
    func stopLiveTranscription() {
        runtime.stopLive()
    }

    // MARK: - 应用退出

    /// 应用退出：取消全部后台任务（ASR / 翻译 / 健康检查 / toast / 转录队列），
    /// 释放模型与推理资源。任何一步失败都不影响退出流程。
    func shutdown() {
        transcriptionQueueTask?.cancel()
        transcriptionQueueTask = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        runtime.shutdown()
    }

    // MARK: - 历史记录操作（页面状态）

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

        transcriptionQueueTask = Task.detached { [service = runtime.service, history] in
            do {
                let result = try await service.transcribe(fileURL: item.fileURL) { progress in
                    Task { @MainActor in
                        item.progress = progress
                    }
                }
                await MainActor.run {
                    item.segments = result.segments
                    item.fullText = result.text
                    // 内存中已是完整内容：标记已载入，允许整体持久化
                    //（懒加载条目未标记时 save 只回写元数据，结果会丢失）。
                    item.transcriptHydrated = true
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

    // MARK: - 崩溃恢复（快照读写由 ASRManager 负责）

    /// Check if there is a recoverable live transcription from a previous crash/hang.
    var hasLiveRecoveryData: Bool {
        ASRManager.hasLiveRecoveryData
    }

    /// Import recovered live transcription as a completed transcription item.
    func importRecoveredTranscription() {
        guard let snapshot = ASRManager.loadRecoveredSnapshot() else { return }
        let item = TranscriptionItem(
            fileURL: URL(fileURLWithPath: "/recovered-\(ISO8601DateFormatter().string(from: snapshot.savedAt))"))
        item.segments = snapshot.segments
        item.fullText = snapshot.fullText
        item.translatedSegments = snapshot.translatedSegments
        item.translationLanguage = snapshot.translationLanguage
        item.status = .completed
        item.fileName = "Recovered \(DateFormatter.localizedString(from: snapshot.savedAt, dateStyle: .short, timeStyle: .short))"
        history.add(item)
        selectedItemID = item.id
        ASRManager.removeRecoveryFile()
    }

    // MARK: - Floating Letter Overlay（样式偏好，纯页面状态）

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

    func setSubtitleContainerWidth(_ value: Double) {
        let clamped = min(max(value, 400), 4000)
        subtitleContainerWidth = clamped
        UserDefaults.standard.set(clamped, forKey: "subtitleFrameWidth")
    }

    func setSubtitleContainerHeight(_ value: Double) {
        let clamped = min(max(value, 100), 2160)
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
        subtitleFontWeight = value
        UserDefaults.standard.set(value, forKey: "subtitleFontWeight")
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
        recordingAlwaysOnTop = alwaysOnTop
    }

    func resetFloatingOverlayPosition() {
        Task { @MainActor in
            FloatingLetterOverlayController.shared.resetPosition()
        }
    }
}
