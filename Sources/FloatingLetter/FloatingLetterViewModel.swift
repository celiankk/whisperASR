import Foundation
import Observation
import CoreGraphics
import SwiftUI

// MARK: - 悬浮字幕浮层 ViewModel
//
// 职责：
// 1. 持有浮层全部 UI 状态（字幕、录制状态、工具栏开关、紧凑模式）；
// 2. 管理“5 秒无操作自动隐藏”的倒计时 Timer；
// 3. 把按钮点击翻译成业务动作——动作本身通过闭包注入（由宿主/桥接层
//    绑定到 AppState、AudioRecorder 等业务对象），从而做到 UI 与业务分离。
//
// 本类不引用 AppState / AudioRecorder，可独立复制到任意 SwiftUI 工程。

@Observable
final class FloatingLetterViewModel {
    // MARK: 常量

    /// 鼠标 5 秒无任何操作后自动淡出隐藏。
    static let idleHideAfter: TimeInterval = 5

    // MARK: 字幕内容

    /// 当前字幕文本（业务层持续推入最新识别结果）。
    var subtitleText = ""
    /// 当前段落的译文（可选）。
    var translationText: String?
    /// 字幕文本是否显示（工具栏“字幕”开关，纯 UI 状态）。
    var subtitleTextVisible = true

    // MARK: 字幕状态（YouTube/B 站式：当前行 + 单条自动消失的历史行）

    /// 一行完整字幕（final transcript / 已结束的识别段落）。
    struct SubtitleLine: Identifiable, Equatable {
        /// 唯一 key：同一行保留同一 id，避免 SplitText 重复播放。
        let id: String
        let text: String
        let translation: String?
        /// 历史行生命周期：visible → exiting → removed（退出只执行一次）。
        var status: HistoryStatus = .visible
    }

    /// 历史行生命周期状态。
    enum HistoryStatus: Equatable {
        case visible
        case exiting
        case removed
    }

    /// 是否正在播放（录制 + 实时转录中）。暂停/停止时冻结历史字幕，
    /// 不创建新的退出计时器、不重复触发动画。
    var isPlaying = false
    /// 最大显示行数（1–3，默认 3，由设置页同步）。
    var maxLines = 2

    // MARK: 单一字幕显示（CurrentRecognition / TranslationResult）

    /// 字幕状态机：Idle / Listening / Recognizing / Translating / Showing。
    var subtitleState: SubtitleState = .idle
    /// 实时识别文本（Recognizing 阶段显示）。
    var recognitionText = ""
    /// 当前显示的是译文（true）还是原文（false）。
    var showingTranslation = false
    /// 全 App 唯一的字幕渲染器（禁止多个 TextOverlay）。
    var renderer = SubtitleRenderer(maxLines: 2)
    /// 译文渲染器：与原文并存（原文在上、译文在下同时显示）。
    var translationRenderer = SubtitleRenderer(maxLines: 2)
    /// 字幕空闲自动清除延迟（默认 3 秒，设置页可配置）。
    var subtitleClearDelay: TimeInterval = 3
    /// 句子端点检测参数（最短 1s / 最长 5s / 停顿 1s）。
    var speechConfig = SpeechEndpointConfig()
    /// 一句结束回调（桥接层接线到 AppState 翻译引擎，一次一句）。
    var onSentenceCompleted: ((String) -> Void)?
    /// 句子端点检测器。
    @ObservationIgnored private var detector = SpeechEndpointDetector()
    /// 句子去重（ASR 重复输出 / 与译文相同只保留一次）。
    @ObservationIgnored private var sentenceDeduplicator = SubtitleDeduplicator()
    /// 延迟统计（ASR → 翻译 → 显示）。
    let latencyManager = SubtitleLatencyManager()
    /// 空闲清除任务：3 秒没有新的 ASR 输入就清空浮窗字幕。
    @ObservationIgnored private var idleClearTask: Task<Void, Never>?
    /// 停顿检测任务（silencePause 后检查句子是否结束）。
    @ObservationIgnored private var sentenceSilenceTask: Task<Void, Never>?
    /// 翻译超时任务（3 秒无结果回退原文，不阻塞下一句）。
    @ObservationIgnored private var translationTimeoutTask: Task<Void, Never>?

    // MARK: 录制状态

    /// 是否正在录制（录制中才展示录制相关控件）。
    var isRecording = false
    /// 监听的软件名称。
    var recordingAppName = "未选择应用"
    /// 格式化后的录制时长（mm:ss）。
    var recordingDurationText = "00:00"

    // MARK: 选择应用阶段（“开始录制 → 选择应用 → 字幕浮层”重写后的入口）

    /// 应用列表加载阶段。
    enum AppListPhase: Equatable {
        case idle
        case loading
        case ready
        case permissionDenied
    }

    /// 浮层内可选的应用（与业务层 SCRunningApplication 解耦的轻量模型）。
    struct FloatingApp: Identifiable, Equatable {
        let id: String      // bundleIdentifier
        let name: String
        let processID: pid_t
    }

    /// 实时转录模型选项。
    struct FloatingModelOption: Identifiable, Equatable {
        let id: String      // fileName（空 = 与转录模型相同）
        let name: String
    }

    /// 是否处于“选择应用”展开态（该阶段浮层放大为选择面板）。
    var isSelectingApp = false
    var appListPhase: AppListPhase = .idle
    var availableApps: [FloatingApp] = []
    var appSearchText = ""
    var selectedAppID: String?
    var appListError: String?

    // 录制选项（与原选择窗口保持一致，不丢功能）。
    // 麦克风初值读「音频」设置的默认包含麦克风。
    var includeMicrophone = UserDefaults.standard.bool(forKey: AudioSettings.includeMicrophoneKey)
    var enableLiveTranscription = true
    var enableLiveTranslation = false
    var liveModelOptions: [FloatingModelOption] = []
    var liveModelSelection = ""

    // MARK: 工具栏状态

    /// 对话气泡：翻译是否暂停。
    var isTranslationPaused = false
    /// 眼睛：是否仅显示译文。
    var translationOnly = false
    /// 图钉：窗口置顶。
    var isPinned = false
    /// 缩放箭头：紧凑/展开模式。
    var isCompact = false
    /// 是否允许闲置自动隐藏（录制中可配置）。
    var autoHideEnabled = true
    /// 控制层可见性状态（ControlVisibilityManager）：
    /// visible / hover = 显示；hidden = 5 秒无操作后隐藏（字幕层不受影响）。
    enum ControlVisibility: Equatable, Hashable {
        case visible
        case hover
        case hidden
    }

    var controlVisibility: ControlVisibility = .visible

    /// 控制层是否可见（视图层使用；hidden 时隐藏且不响应点击）。
    var controlsVisible: Bool {
        controlVisibility != .hidden
    }

    // MARK: 字幕容器（SubtitleContainerLayer）配置——与字体完全解耦

    /// 字幕容器宽度（独立于字号，400–1200）。
    var subtitleContainerWidth: CGFloat = 800
    /// 字幕容器高度（独立于字号，100–400）。
    var subtitleContainerHeight: CGFloat = 240
    /// 容器背景透明度。
    var subtitleBackgroundOpacity: Double = 0.34
    /// 字幕编辑边框（默认显示，可设置隐藏/颜色/透明度）。
    var subtitleEditBorderVisible = true
    /// 编辑边框颜色（十六进制字符串，如 "FFFFFF"）。
    var subtitleEditBorderColorHex = "FFFFFF"
    /// 编辑边框透明度（0–1）。
    var subtitleEditBorderOpacity: Double = 0.8
    /// 鼠标穿透（默认关闭）：开启后窗口 ignoresMouseEvents，只显示字幕。
    var mousePassthrough = false

    // MARK: 字幕文字（SubtitleTextLayer）配置

    /// 字体粗细：regular / medium / bold。
    var subtitleFontWeight = "medium"
    /// 行间距（pt）。
    var subtitleLineSpacing: CGFloat = 2

    /// 容器尺寸/位置变化回调（编辑模式 → 持久化到 AppState）。
    var onContainerResized: ((CGFloat, CGFloat) -> Void)?
    var onMousePassthroughChanged: ((Bool) -> Void)?

    // MARK: 样式（由设置页同步，保持旧设置项继续生效）

    /// 原文（主字幕）字号。
    var sourceFontSize: CGFloat = 17
    /// 译文字号。
    var translationFontSize: CGFloat = 13
    /// 边框不透明度。
    var borderOpacity: Double = 0.1
    /// 字幕水平对齐（设置页可切换，默认居中；不影响窗口位置）。
    var subtitleTextAlignment: TextAlignment = .center

    // MARK: 调试信息（开发模式显示，确认中文是否绕过翻译）

    struct SubtitleDebugInfo: Equatable {
        var asrText: String
        var detectedLanguage: String
        var translationStatus: String
        var audioLevelText: String
        var subtitle: String
        var latencyMs: Int
        /// 引擎健康度（内存/任务/缓冲/模型），开发模式显示。
        var engineInfo: String
    }

    /// 最近一次字幕处理链路调试信息（ASR / 语言 / 翻译状态 / 字幕）。
    var debugInfo: SubtitleDebugInfo?

    // MARK: 业务动作（由宿主注入，实现 UI 与业务分离）

    var onToggleTranslationPause: (() -> Void)?
    var onToggleTranslationOnly: (() -> Void)?
    /// 字幕开关回调（携带新值，便于宿主同步业务状态）。
    var onToggleSubtitle: ((Bool) -> Void)?
    /// 置顶开关回调（携带新值）。
    var onTogglePin: ((Bool) -> Void)?
    var onCancelRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?
    /// 点击关闭按钮（控制器据此销毁窗口）。
    var onClose: (() -> Void)?
    /// 关闭后的业务回调（宿主据此持久化“已关闭”偏好等）。
    var onClosed: (() -> Void)?
    /// 倒计时超时回调（控制器据此执行淡出隐藏）。
    var onIdleTimeout: (() -> Void)?
    /// 紧凑/展开切换回调（控制器据此调整窗口尺寸）。
    var onCompactChanged: ((Bool) -> Void)?
    /// 选择应用阶段切换回调（控制器据此放大/还原窗口）。
    var onSelectingChanged: ((Bool) -> Void)?

    // MARK: 选择应用阶段的业务动作（由桥接层注入）

    var onStartAppSelection: (() -> Void)?
    var onCancelAppSelection: (() -> Void)?
    var onSelectApp: ((String) -> Void)?
    var onConfirmRecording: (() -> Void)?
    var onRetryLoadApps: (() -> Void)?
    var onOpenSystemSettings: (() -> Void)?
    var onToggleIncludeMicrophone: ((Bool) -> Void)?
    var onToggleLiveTranscription: ((Bool) -> Void)?
    var onToggleLiveTranslation: ((Bool) -> Void)?
    var onLiveModelSelectionChanged: ((String) -> Void)?

    // MARK: 私有状态

    /// 闲置倒计时 Timer。用 @ObservationIgnored 标记，避免被 Observation
    /// 追踪（Timer 本身不是 UI 状态）。
    @ObservationIgnored private var idleTimer: Timer?
    /// teardown 后不再启动新的倒计时。
    @ObservationIgnored private var isTornDown = false

    init() {
#if DEBUG
        FloatingLetterLeakState.viewModelAlive += 1
#endif
    }

    deinit {
        // 兜底：ViewModel 销毁时主动 invalidate 定时器，防止内存泄漏。
        invalidateIdleTimer()
        idleClearTask?.cancel()
        sentenceSilenceTask?.cancel()
        translationTimeoutTask?.cancel()
#if DEBUG
        FloatingLetterLeakState.viewModelAlive -= 1
        print("[FloatingLetter] ViewModel deinit, alive=\(FloatingLetterLeakState.viewModelAlive)")
#endif
    }

    // MARK: - 字幕展示逻辑

    /// 去除首尾空白后的译文；空字符串视为无译文。
    var nonEmptyTranslation: String? {
        guard let text = translationText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else { return nil }
        return text
    }

    /// 浮层中央实际展示的主字幕文本（含空状态占位）。
    var displayedSubtitleText: String {
        if translationOnly {
            if showingTranslation, let translation = translationText, !translation.isEmpty {
                return translation
            }
            if !recognitionText.isEmpty { return recognitionText }
            return subtitleTextVisible ? "等待翻译…" : "字幕已隐藏"
        }
        if subtitleTextVisible {
            return subtitleText.isEmpty ? "" : subtitleText
        }
        return "字幕已隐藏"
    }

    // MARK: - 生命周期

    /// 视图出现：开始 5 秒倒计时。
    func viewDidAppear() {
        registerInteraction()
    }

    /// 视图销毁：主动 invalidate 定时器，防止内存泄漏。
    func viewDidDisappear() {
        invalidateIdleTimer()
    }

    /// 彻底清理（控制器销毁浮层时调用，幂等）。
    func teardown() {
        isTornDown = true
        invalidateIdleTimer()
        idleClearTask?.cancel()
        sentenceSilenceTask?.cancel()
        translationTimeoutTask?.cancel()
    }

    // MARK: - 闲置自动隐藏计时器

    /// 任意交互（点击、鼠标移动、进入浮层）后调用，重置 5 秒倒计时。
    func registerInteraction() {
        // 交互时显示控制层；5 秒无操作后由 idle 计时器隐藏控制层（字幕层不动）。
        controlVisibility = .visible
        resetIdleTimer()
    }

    private func resetIdleTimer() {
        invalidateIdleTimer()
        // 选择应用阶段不自动隐藏（用户可能正在浏览应用列表）。
        // 穿透模式不监听鼠标、不显示控制栏；普通/编辑模式才启用自动隐藏。
        guard autoHideEnabled, !isTornDown, !isSelectingApp, !mousePassthrough else { return }
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleHideAfter,
            repeats: false
        ) { [weak self] _ in
            guard let self, !self.isTornDown else { return }
            // 只隐藏控制层，字幕层继续显示。
            self.controlVisibility = .hidden
            self.onIdleTimeout?()
        }
    }

    /// 主动 invalidate 定时器（View 销毁、关闭浮层、deinit 时都会调用）。
    func invalidateIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - 工具栏动作
    //
    // 每个动作都会先 registerInteraction()，保证“点击浮层内任意控件
    // 重置 5 秒倒计时”。

    func toggleTranslationPause() {
        registerInteraction()
        onToggleTranslationPause?()
    }

    func toggleTranslationOnly() {
        registerInteraction()
        onToggleTranslationOnly?()
    }

    func toggleSubtitle() {
        registerInteraction()
        subtitleTextVisible.toggle()
        onToggleSubtitle?(subtitleTextVisible)
    }

    func togglePin() {
        registerInteraction()
        isPinned.toggle()
        onTogglePin?(isPinned)
    }

    func toggleCompact() {
        registerInteraction()
        isCompact.toggle()
        onCompactChanged?(isCompact)
    }

    // MARK: - 选择应用阶段动作

    /// 进入选择应用模式（浮层放大为选择面板并加载应用列表）。
    func startAppSelection() {
        registerInteraction()
        isSelectingApp = true
        appSearchText = ""
        onSelectingChanged?(true)
        onStartAppSelection?()
    }

    /// 取消选择：还原浮层并通知业务层清理选择状态。
    func cancelAppSelection() {
        registerInteraction()
        isSelectingApp = false
        selectedAppID = nil
        onSelectingChanged?(false)
        registerInteraction()
        onCancelAppSelection?()
    }

    /// 点击浮层外空白处返回：仅退出选择模式（回到空闲长条），
    /// 不取消任何录制业务状态，也不关闭浮层。
    func dismissAppSelection() {
        isSelectingApp = false
        selectedAppID = nil
        onSelectingChanged?(false)
        registerInteraction()
    }

    /// 选中一个应用。
    func selectApp(id: String) {
        registerInteraction()
        selectedAppID = id
        onSelectApp?(id)
    }

    /// 确认开始录制：退出选择模式并启动录制。
    func confirmRecording() {
        isSelectingApp = false
        onSelectingChanged?(false)
        // 退出选择模式后再武装自动隐藏计时器（选择阶段不自动隐藏）。
        registerInteraction()
        onConfirmRecording?()
    }

    func retryLoadApps() {
        registerInteraction()
        onRetryLoadApps?()
    }

    func openSystemSettings() {
        registerInteraction()
        onOpenSystemSettings?()
    }

    func toggleIncludeMicrophone() {
        registerInteraction()
        includeMicrophone.toggle()
        onToggleIncludeMicrophone?(includeMicrophone)
    }

    func toggleLiveTranscription() {
        registerInteraction()
        enableLiveTranscription.toggle()
        if !enableLiveTranscription {
            enableLiveTranslation = false
        }
        onToggleLiveTranscription?(enableLiveTranscription)
    }

    func toggleLiveTranslation() {
        registerInteraction()
        enableLiveTranslation.toggle()
        onToggleLiveTranslation?(enableLiveTranslation)
    }

    func setLiveModelSelection(_ fileName: String) {
        registerInteraction()
        liveModelSelection = fileName
        onLiveModelSelectionChanged?(fileName)
    }

    func cancelRecording() {
        registerInteraction()
        onCancelRecording?()
    }

    func endRecording() {
        registerInteraction()
        onEndRecording?()
    }

    func close() {
        invalidateIdleTimer()
        onClose?()
        onClosed?()
    }

    // MARK: - 字幕处理管线（单一渲染入口）
    //
    // 流程：麦克风 → ASR → 实时显示（Recognizing）→ 端点检测（停顿/标点/最长 5s）
    //       → 整句翻译（Translating，一次一句）→ 译文替换显示（Showing）→ 下一句。
    // 全 App 只有一个 SubtitleRenderer（renderer），禁止多处 TextOverlay。

    /// 字幕容器高度（SubtitleContainerConfig.height）。
    /// 与字体完全解耦：调整字号不会改变窗口/容器尺寸。
    var requiredSubtitleHeight: CGFloat {
        subtitleContainerHeight
    }

    /// 切换鼠标穿透（编辑模式下按钮禁用，不响应）。
    func toggleMousePassthrough() {
        mousePassthrough.toggle()
        if mousePassthrough {
            // 穿透：立即隐藏控制栏并停止闲置计时。
            controlVisibility = .hidden
            invalidateIdleTimer()
        } else {
            controlVisibility = .visible
            registerInteraction()
        }
        onMousePassthroughChanged?(mousePassthrough)
    }

    /// 编辑模式：调整容器尺寸（下限 400×100，上限 4000×2160 覆盖全屏窗口）。
    /// 无变化直接返回：窗口移动也会触发同步，避免无意义的
    /// @Observable 变更与持久化写入（防状态循环）。
    func adjustSubtitleContainer(width: CGFloat, height: CGFloat) {
        let w = min(max(width, 400), 4000)
        let h = min(max(height, 100), 2160)
        guard w != subtitleContainerWidth || h != subtitleContainerHeight else { return }
        subtitleContainerWidth = w
        subtitleContainerHeight = h
        onContainerResized?(w, h)
    }

    /// 由桥接层在每次识别快照变化时调用；所有字幕只经过这一个入口。
    func updateSubtitleState(
        final: [SubtitleLine],
        interimText: String,
        interimTranslation: String?,
        isPlaying: Bool
    ) {
        self.isPlaying = isPlaying

        // 录制结束/清空：全部清空。
        if final.isEmpty, interimText.isEmpty {
            resetSubtitleDisplay()
            return
        }

        // 暂停冻结：停止刷新、取消空闲清除，但不清空已有字幕。
        if !isPlaying {
            idleClearTask?.cancel()
            sentenceSilenceTask?.cancel()
            translationTimeoutTask?.cancel()
            return
        }

        latencyManager.markInput()

        // whisper 封口 = 一句结束（停顿检测由 ASR 静音 seal 完成）。
        if let newest = final.last, interimText.isEmpty {
            handleSentenceCompleted(newest.text)
            return
        }

        // 流式识别 → 端点检测（停顿/标点/最长时长）。
        switch detector.update(text: interimText) {
        case .speechStarted:
            // 不足最短识别时长：不显示（避免嗯/啊/单字触发）。
            subtitleState = .listening
            scheduleSilenceCheck()
        case .recognized(let text):
            // 最短识别时长：不足 1 秒不显示（避免嗯/啊/单字触发）。
            if let started = detector.speechStartedAt,
               Date().timeIntervalSince(started) >= speechConfig.minimumSpeechDuration {
                recognitionText = text
                subtitleState = .recognizing
                renderText(text)
                scheduleSilenceCheck()
                scheduleIdleClear()
            } else {
                subtitleState = .listening
            }
        case .sentenceEnded(let sentence):
            handleSentenceCompleted(sentence)
        case .discarded:
            subtitleState = .listening
        case .none:
            break
        }
    }

    /// 一句结束：去重 → 显示原文 → 触发整句翻译（只发一次 API）。
    private func handleSentenceCompleted(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 去重：近期相同句子不重复翻译/显示（防 ASR 重复输出）。
        guard sentenceDeduplicator.decide(trimmed) != .suppress else { return }
        sentenceDeduplicator.record(trimmed)

        // 显示原文，进入 Translating（不阻塞下一句）；清空上一句的译文区。
        recognitionText = trimmed
        translationText = nil
        showingTranslation = false
        translationRenderer.clear()
        subtitleState = .translating
        renderText(trimmed)
        onSentenceCompleted?(trimmed)
        scheduleTranslationTimeout()
        scheduleIdleClear()
    }

    /// 翻译结果返回：原文保持显示，译文渲染到下方译文区（原文+译文同时显示）。
    /// 迟到容忍：只要当前显示的仍是这一句（recognitionText 未变）就接受，
    /// 不论状态机已走到哪一步；新的一句已开始（文本变了）则丢弃，避免串行。
    func setTranslationResult(for source: String, translation: String?) {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, trimmedSource == recognitionText else { return }
        let t = translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        latencyManager.markTranslated()
        if t.isEmpty || t == trimmedSource {
            showingTranslation = false
            translationText = nil
            translationRenderer.clear()
        } else {
            showingTranslation = true
            translationText = t
            renderTranslation(t)
        }
        subtitleState = .showing
        scheduleIdleClear()
    }

    /// 单一渲染入口：断句（中文 30 / 英文 80）→ 渲染器（≤2 行，不省略）。
    private func renderText(_ text: String) {
        let splitter = SubtitleSentenceSplitter()
        let lines = splitter.split(text, language: SubtitleLanguage.detect(text))
        renderer.maxLines = 2
        _ = withAnimation(.easeOut(duration: 0.18)) {
            renderer.setLines(Array(lines.prefix(2)))
        }
        subtitleText = renderer.text
        latencyManager.markDisplayed()
    }

    /// 译文渲染入口：独立于原文渲染器（原文保持不动，译文出现在下方）。
    private func renderTranslation(_ text: String) {
        let splitter = SubtitleSentenceSplitter()
        let lines = splitter.split(text, language: SubtitleLanguage.detect(text))
        translationRenderer.maxLines = 2
        _ = withAnimation(.easeOut(duration: 0.18)) {
            translationRenderer.setLines(Array(lines.prefix(2)))
        }
    }

    /// 字幕空闲自动清除：subtitleClearDelay 秒没有新的 ASR 输入 → 清空浮窗，
    /// 不显示“等待中 / 灰色文字 / 占位符”。
    private func scheduleIdleClear() {
        idleClearTask?.cancel()
        let delay = subtitleClearDelay
        idleClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isPlaying else { return }
            self.resetSubtitleDisplay()
        }
    }

    /// 停顿检测：silencePause 后无新输入 → 一句结束。
    private func scheduleSilenceCheck() {
        sentenceSilenceTask?.cancel()
        let pause = speechConfig.silencePause
        sentenceSilenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(pause))
            guard let self, !Task.isCancelled, self.isPlaying else { return }
            if case .sentenceEnded(let sentence) = self.detector.checkSilence() {
                self.handleSentenceCompleted(sentence)
            }
        }
    }

    /// 翻译超时兜底：3 秒无结果只显示原文，不阻塞下一句。
    private func scheduleTranslationTimeout() {
        translationTimeoutTask?.cancel()
        translationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.subtitleState == .translating else { return }
            self.subtitleState = .showing
            self.showingTranslation = false
            self.translationRenderer.clear()
            self.scheduleIdleClear()
        }
    }

    /// 清空浮窗字幕（空闲超时 / 录制结束共用）。
    private func resetSubtitleDisplay() {
        idleClearTask?.cancel()
        sentenceSilenceTask?.cancel()
        translationTimeoutTask?.cancel()
        detector.reset()
        sentenceDeduplicator.reset()
        latencyManager.reset()
        renderer.clear()
        translationRenderer.clear()
        recognitionText = ""
        translationText = nil
        showingTranslation = false
        subtitleState = isPlaying ? .listening : .idle
        subtitleText = ""
    }

    // MARK: - 工具方法

    /// 秒数格式化为 mm:ss。
    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
