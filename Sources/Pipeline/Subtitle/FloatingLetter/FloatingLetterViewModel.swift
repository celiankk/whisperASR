import Foundation
import Observation
import CoreGraphics
import SwiftUI

// MARK: - 悬浮字幕浮层 ViewModel（业务编排门面）
//
// P1 渲染优化重构：本类不再持有任何视图可见状态——
// - 高频字幕流状态 → `stream: SubtitleStreamModel`（每次 ASR 快照写入）；
// - 低频控制/工具栏状态 → `controls: OverlayControlModel`（用户点击 /
//   设置同步 / 秒级计时驱动）；
// - 本类只保留：业务管线（断句/去重/翻译调度/定时器）、动作回调、
//   以及指向两个状态模型的**兼容计算属性**。
//
// 兼容层说明：@Observable 宏只对存储属性注册追踪，委托计算属性不注册
// VM 自身——控制器/桥接层经 `vm.isPinned` 等既有路径读写时，追踪仍然
// 落在真正的数据源（controls/stream）上，视图隔离不被破坏。
//
// 本类不引用 AppState / AudioRecorder，可独立复制到任意 SwiftUI 工程。

@Observable
final class FloatingLetterViewModel {
    // MARK: 状态模型（物理隔离的两个数据源）

    /// 高频字幕流状态（SubtitleStreamSection 专属数据源）。
    let stream = SubtitleStreamModel()
    /// 低频控制/工具栏状态（OverlayControlBar / 窗口控制器数据源）。
    let controls = OverlayControlModel()

    // MARK: 兼容类型别名（嵌套类型随状态迁入 controls，引用零改动）

    typealias FloatingApp = OverlayControlModel.FloatingApp
    typealias FloatingModelOption = OverlayControlModel.FloatingModelOption
    typealias AppListPhase = OverlayControlModel.AppListPhase
    typealias ControlVisibility = OverlayControlModel.ControlVisibility

    // MARK: 常量

    /// 鼠标 5 秒无任何操作后自动淡出隐藏。
    static let idleHideAfter: TimeInterval = 5

    // MARK: 中频业务状态（不进视图模型：无视图直接读取）

    /// 是否正在播放（录制 + 实时转录中）。暂停/停止时冻结历史字幕，
    /// 不创建新的退出计时器、不重复触发动画。
    /// 写入侧做等值守卫：updateSubtitleState 每个快照都会到达这里，
    /// 等值写入不触发 Observation 变更（防快照频率污染观察者）。
    private(set) var isPlaying = false
    /// 字幕空闲自动清除延迟（默认 3 秒，设置页可配置）。
    var subtitleClearDelay: TimeInterval = 3

    // MARK: 字幕管线内部状态（@ObservationIgnored：非 UI 状态）

    /// 一句结束回调（桥接层接线到 AppState 翻译引擎，一次一句）。
    var onSentenceCompleted: ((String) -> Void)?
    /// 句子端点检测器。
    @ObservationIgnored private var detector = SpeechEndpointDetector(config: SpeechEndpointConfig())
    /// 句子去重（ASR 重复输出 / 与译文相同只保留一次）。
    @ObservationIgnored private var sentenceDeduplicator = SubtitleDeduplicator()
    /// 最近一次触发翻译的 final 段文本（Apple 引擎以「新 final 段」为句子完成信号）。
    @ObservationIgnored private var lastSentenceFinalText = ""
    /// 新句判定器（判据与理由见 SubtitleSentenceTrigger）。
    @ObservationIgnored private var sentenceTrigger = SubtitleSentenceTrigger()
    /// 最近一次翻译请求的句子文本（译文归属校验用）。
    @ObservationIgnored private var lastTranslationRequestSource = ""
    /// 最近一次处理过的输入快照签名（幂等门：相同快照直接跳过）。
    @ObservationIgnored private var lastProcessedInputSignature: String?
    /// 最近一次 interim（partial）重绘时间：逐字 partial 做最小间隔节流，
    /// 把字符级 dribble 合并成小段更新，读起来更像句子而不是高频闪字。
    /// 句子完成（sentenceEnded / final 完成）路径不受节流。
    @ObservationIgnored private var lastInterimRenderDate = Date.distantPast
    /// 延迟统计（ASR → 翻译 → 显示）。
    let latencyManager = SubtitleLatencyManager()
    /// 空闲清除任务：3 秒没有新的 ASR 输入就清空浮窗字幕。
    @ObservationIgnored private var idleClearTask: Task<Void, Never>?
    /// 翻译超时任务（3 秒无结果回退原文，不阻塞下一句）。
    @ObservationIgnored private var translationTimeoutTask: Task<Void, Never>?

    // MARK: 容器/模式回调（控制器与业务层接线）

    /// 容器尺寸/位置变化回调（编辑模式 → 持久化到 AppState）。
    var onContainerResized: ((CGFloat, CGFloat) -> Void)?
    var onMousePassthroughChanged: ((Bool) -> Void)?

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
    /// 关闭后的业务回调（宿主据此持久化「已关闭」偏好等）。
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

    // MARK: 调试信息类型（值本身随快照进 stream.debugInfo）

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
        translationTimeoutTask?.cancel()
#if DEBUG
        FloatingLetterLeakState.viewModelAlive -= 1
        print("[FloatingLetter] ViewModel deinit, alive=\(FloatingLetterLeakState.viewModelAlive)")
#endif
    }

    // MARK: - 兼容计算属性（委托层：控制器/桥接层既有引用零改动）
    //
    // @Observable 只追踪存储属性——这里的计算属性不注册 VM 自身，
    // 读写追踪直接穿透到 stream/controls 数据源（隔离不被破坏）。

    // MARK: 高频域委托（stream）

    var subtitleText: String {
        get { stream.subtitleText }
        set { stream.subtitleText = newValue }
    }
    var translationText: String? {
        get { stream.translationText }
        set { stream.translationText = newValue }
    }
    var recognitionText: String {
        get { stream.recognitionText }
        set { stream.recognitionText = newValue }
    }
    var showingTranslation: Bool {
        get { stream.showingTranslation }
        set { stream.showingTranslation = newValue }
    }
    var subtitleState: SubtitleState {
        get { stream.subtitleState }
        set { stream.subtitleState = newValue }
    }
    var renderer: SubtitleRenderer {
        get { stream.renderer }
        set { stream.renderer = newValue }
    }
    var translationRenderer: SubtitleRenderer {
        get { stream.translationRenderer }
        set { stream.translationRenderer = newValue }
    }
    var debugInfo: SubtitleDebugInfo? {
        get { stream.debugInfo }
        set { stream.debugInfo = newValue }
    }
    var nonEmptyTranslation: String? { stream.nonEmptyTranslation }

    // MARK: 低频域委托（controls）

    var subtitleTextVisible: Bool {
        get { controls.subtitleTextVisible }
        set { controls.subtitleTextVisible = newValue }
    }
    var maxLines: Int {
        get { controls.maxLines }
        set { controls.maxLines = newValue }
    }
    var isTranslationPaused: Bool {
        get { controls.isTranslationPaused }
        set { controls.isTranslationPaused = newValue }
    }
    var translationOnly: Bool {
        get { controls.translationOnly }
        set { controls.translationOnly = newValue }
    }
    var isPinned: Bool {
        get { controls.isPinned }
        set { controls.isPinned = newValue }
    }
    var isCompact: Bool {
        get { controls.isCompact }
        set { controls.isCompact = newValue }
    }
    var autoHideEnabled: Bool {
        get { controls.autoHideEnabled }
        set { controls.autoHideEnabled = newValue }
    }
    var mousePassthrough: Bool {
        get { controls.mousePassthrough }
        set { controls.mousePassthrough = newValue }
    }
    var controlVisibility: ControlVisibility {
        get { controls.controlVisibility }
        set { controls.controlVisibility = newValue }
    }
    var controlsVisible: Bool { controls.controlsVisible }
    var controlsCollapsed: Bool {
        get { controls.controlsCollapsed }
        set { controls.controlsCollapsed = newValue }
    }
    var isRecording: Bool {
        get { controls.isRecording }
        set { controls.isRecording = newValue }
    }
    var recordingAppName: String {
        get { controls.recordingAppName }
        set { controls.recordingAppName = newValue }
    }
    var recordingDurationText: String {
        get { controls.recordingDurationText }
        set { controls.recordingDurationText = newValue }
    }
    var isSelectingApp: Bool {
        get { controls.isSelectingApp }
        set { controls.isSelectingApp = newValue }
    }
    var appListPhase: AppListPhase {
        get { controls.appListPhase }
        set { controls.appListPhase = newValue }
    }
    var availableApps: [FloatingApp] {
        get { controls.availableApps }
        set { controls.availableApps = newValue }
    }
    var appSearchText: String {
        get { controls.appSearchText }
        set { controls.appSearchText = newValue }
    }
    var selectedAppID: String? {
        get { controls.selectedAppID }
        set { controls.selectedAppID = newValue }
    }
    var appListError: String? {
        get { controls.appListError }
        set { controls.appListError = newValue }
    }
    var includeMicrophone: Bool {
        get { controls.includeMicrophone }
        set { controls.includeMicrophone = newValue }
    }
    var enableLiveTranscription: Bool {
        get { controls.enableLiveTranscription }
        set { controls.enableLiveTranscription = newValue }
    }
    var enableLiveTranslation: Bool {
        get { controls.enableLiveTranslation }
        set { controls.enableLiveTranslation = newValue }
    }
    var liveModelOptions: [FloatingModelOption] {
        get { controls.liveModelOptions }
        set { controls.liveModelOptions = newValue }
    }
    var liveModelSelection: String {
        get { controls.liveModelSelection }
        set { controls.liveModelSelection = newValue }
    }
    var subtitleContainerWidth: CGFloat {
        get { controls.subtitleContainerWidth }
        set { controls.subtitleContainerWidth = newValue }
    }
    var subtitleContainerHeight: CGFloat {
        get { controls.subtitleContainerHeight }
        set { controls.subtitleContainerHeight = newValue }
    }
    var subtitleBackgroundOpacity: Double {
        get { controls.subtitleBackgroundOpacity }
        set { controls.subtitleBackgroundOpacity = newValue }
    }
    var subtitleEditBorderVisible: Bool {
        get { controls.subtitleEditBorderVisible }
        set { controls.subtitleEditBorderVisible = newValue }
    }
    var subtitleEditBorderColorHex: String {
        get { controls.subtitleEditBorderColorHex }
        set { controls.subtitleEditBorderColorHex = newValue }
    }
    var subtitleEditBorderOpacity: Double {
        get { controls.subtitleEditBorderOpacity }
        set { controls.subtitleEditBorderOpacity = newValue }
    }
    var subtitleFontWeight: String {
        get { controls.subtitleFontWeight }
        set { controls.subtitleFontWeight = newValue }
    }
    var subtitleLineSpacing: CGFloat {
        get { controls.subtitleLineSpacing }
        set { controls.subtitleLineSpacing = newValue }
    }
    var sourceFontSize: CGFloat {
        get { controls.sourceFontSize }
        set { controls.sourceFontSize = newValue }
    }
    var translationFontSize: CGFloat {
        get { controls.translationFontSize }
        set { controls.translationFontSize = newValue }
    }
    var borderOpacity: Double {
        get { controls.borderOpacity }
        set { controls.borderOpacity = newValue }
    }
    var subtitleTextAlignment: TextAlignment {
        get { controls.subtitleTextAlignment }
        set { controls.subtitleTextAlignment = newValue }
    }

    // MARK: - 派生显示（跨两域只读；追踪穿透到两模型）

    /// 浮层中央实际展示的主字幕文本（含空状态占位）。
    var displayedSubtitleText: String {
        if controls.translationOnly {
            // 译文有效性走去空白判定（与 nonEmptyTranslation 一致）：
            // 纯空白译文视为无译文，回退识别文本。
            if stream.showingTranslation, let translation = stream.nonEmptyTranslation {
                return translation
            }
            if !stream.recognitionText.isEmpty { return stream.recognitionText }
            return controls.subtitleTextVisible ? "等待翻译…" : "字幕已隐藏"
        }
        if controls.subtitleTextVisible {
            return stream.subtitleText.isEmpty ? "" : stream.subtitleText
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
        translationTimeoutTask?.cancel()
        // 同 resetSubtitleDisplay：排队中的句子若不清掉，会在销毁后
        // 触发一次 renderText（把上一句画回已关闭的浮层）。
        pendingSentenceTask?.cancel()
        pendingSentenceTask = nil
        pendingSentenceText = nil
        deferredTranslation = nil
    }

    // MARK: - 闲置自动隐藏计时器

    /// 任意交互（点击、鼠标移动、进入浮层）后调用，重置 5 秒倒计时。
    func registerInteraction() {
        // 交互时显示控制层；5 秒无操作后由 idle 计时器隐藏控制层（字幕层不动）。
        controls.controlVisibility = .visible
        resetIdleTimer()
    }

    private func resetIdleTimer() {
        invalidateIdleTimer()
        // 选择应用阶段不自动隐藏（用户可能正在浏览应用列表）。
        // 穿透模式不监听鼠标、不显示控制栏；普通/编辑模式才启用自动隐藏。
        guard controls.autoHideEnabled, !isTornDown, !controls.isSelectingApp, !controls.mousePassthrough else { return }
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleHideAfter,
            repeats: false
        ) { [weak self] _ in
            guard let self, !self.isTornDown else { return }
            // 只隐藏控制层，字幕层继续显示。
            self.controls.controlVisibility = .hidden
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
    // 每个动作都会先 registerInteraction()，保证「点击浮层内任意控件
    // 重置 5 秒倒计时」。状态写入 controls（低频域）。

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
        controls.subtitleTextVisible.toggle()
        onToggleSubtitle?(controls.subtitleTextVisible)
    }

    func togglePin() {
        registerInteraction()
        controls.isPinned.toggle()
        onTogglePin?(controls.isPinned)
    }

    func toggleCompact() {
        registerInteraction()
        controls.isCompact.toggle()
        onCompactChanged?(controls.isCompact)
    }

    /// 切换功能区收起/展开（手动操作，重置 5 秒自动隐藏计时）。
    func toggleControlsCollapsed() {
        registerInteraction()
        controls.controlsCollapsed.toggle()
    }

    // MARK: - 选择应用阶段动作

    /// 进入选择应用模式（浮层放大为选择面板并加载应用列表）。
    func startAppSelection() {
        registerInteraction()
        controls.isSelectingApp = true
        controls.appSearchText = ""
        onSelectingChanged?(true)
        onStartAppSelection?()
    }

    /// 取消选择：还原浮层并通知业务层清理选择状态。
    func cancelAppSelection() {
        registerInteraction()
        controls.isSelectingApp = false
        controls.selectedAppID = nil
        onSelectingChanged?(false)
        registerInteraction()
        onCancelAppSelection?()
    }

    /// 点击浮层外空白处返回：仅退出选择模式（回到空闲长条），
    /// 不取消任何录制业务状态，也不关闭浮层。
    func dismissAppSelection() {
        controls.isSelectingApp = false
        controls.selectedAppID = nil
        onSelectingChanged?(false)
        registerInteraction()
    }

    /// 选中一个应用。
    func selectApp(id: String) {
        registerInteraction()
        controls.selectedAppID = id
        onSelectApp?(id)
    }

    /// 确认开始录制：退出选择模式并启动录制。
    func confirmRecording() {
        controls.isSelectingApp = false
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
        controls.includeMicrophone.toggle()
        onToggleIncludeMicrophone?(controls.includeMicrophone)
    }

    func toggleLiveTranscription() {
        registerInteraction()
        controls.enableLiveTranscription.toggle()
        // 翻译依赖转录：转录关闭期间翻译不生效（UI 禁用），但不重置
        // 用户的翻译选择——重新开启转录后自动恢复之前的翻译状态。
        onToggleLiveTranscription?(controls.enableLiveTranscription)
    }

    func toggleLiveTranslation() {
        registerInteraction()
        controls.enableLiveTranslation.toggle()
        onToggleLiveTranslation?(controls.enableLiveTranslation)
    }

    func setLiveModelSelection(_ fileName: String) {
        registerInteraction()
        controls.liveModelSelection = fileName
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
    // 全 App 只有一个 SubtitleRenderer（stream.renderer），禁止多处 TextOverlay。

    /// 字幕容器高度（SubtitleContainerConfig.height）。
    /// 与字体完全解耦：调整字号不会改变窗口/容器尺寸。
    var requiredSubtitleHeight: CGFloat {
        controls.subtitleContainerHeight
    }

    /// 切换鼠标穿透（编辑模式下按钮禁用，不响应）。
    func toggleMousePassthrough() {
        controls.mousePassthrough.toggle()
        if controls.mousePassthrough {
            // 穿透：立即隐藏控制栏并停止闲置计时。
            controls.controlVisibility = .hidden
            invalidateIdleTimer()
        } else {
            controls.controlVisibility = .visible
            registerInteraction()
        }
        onMousePassthroughChanged?(controls.mousePassthrough)
    }

    /// 编辑模式：调整容器尺寸（下限 400×100，上限 4000×2160 覆盖全屏窗口）。
    /// 无变化直接返回：窗口移动也会触发同步，避免无意义的
    /// @Observable 变更与持久化写入（防状态循环）。
    func adjustSubtitleContainer(width: CGFloat, height: CGFloat) {
        let w = min(max(width, 400), 4000)
        let h = min(max(height, 100), 2160)
        guard w != controls.subtitleContainerWidth || h != controls.subtitleContainerHeight else { return }
        controls.subtitleContainerWidth = w
        controls.subtitleContainerHeight = h
        onContainerResized?(w, h)
    }

    /// 由桥接层在每次识别快照变化时调用；所有字幕只经过这一个入口。
    ///
    /// 刷新逻辑（幂等原则）：显示状态必须是输入（final + interim）的纯函数——
    /// 相同输入必须产生相同画面，绝不重复触发渲染/翻译/清除计时：
    /// 1. 输入级幂等门：同一快照重复推送（静音轮询每秒一次 / 观察者节流 /
    ///    ASR 状态抖动）直接跳过；
    /// 2. 句子完成只认「新 final 文本」（旧文本重复推送不触发）；
    /// 3. 已完成句子的回声（静音封口后最后一段被封口句顶替为 interim）
    ///    不作为新句渲染；
    /// 4. 空闲清除只清画面，不清去重/完成记忆——否则同一句在清除后会被
    ///    重新判定为新句 → 渲染 → 再清除 → 周期性闪烁。
    func updateSubtitleState(
        final: [SubtitleLine],
        interimText: String,
        interimTranslation: String?,
        isPlaying: Bool
    ) {
        // 等值守卫：快照级高频路径上，等值写入不触发 Observation 变更。
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
        }

        // 输入级幂等门：快照签名相同 → 什么都不做（不重渲染、不重启空闲
        // 清除、不重走完成/检测路径）。签名含译文——译文异步到达时快照
        // 变化，正常放行。
        let signature = Self.inputSignature(final: final, interimText: interimText)
        guard signature != lastProcessedInputSignature else { return }
        lastProcessedInputSignature = signature

        AppLogger.shared.log(.ui, "[Renderer] updateSubtitleState final=\(final.count) interim=\(interimText.prefix(32)) isPlaying=\(isPlaying)")

        // 排查直通：绕过句子端点/最短时长/去重，任何非空文本直接显示。
        if SubtitleDebug.bypassFilters {
            if !interimText.isEmpty {
                stream.recognitionText = interimText
                stream.subtitleState = .recognizing
                renderText(interimText)
                scheduleIdleClear()
            } else if let newest = final.last {
                handleSentenceCompleted(newest.text)
            } else {
                resetSubtitleDisplay(clearMemory: true)
            }
            return
        }

        // 录制结束/清空：全部清空。
        if final.isEmpty, interimText.isEmpty {
            // 走 AppLogger（带锁 + 0.3s 异步批量 flush）：裸 print 是同步
            // stdout 写，本方法在 150ms 节流的快照路径上，输出被重定向到
            // 文件/管道时每行一次 write syscall。
            AppLogger.shared.log(.ui, "[Renderer] reset (empty final+interim)")
            resetSubtitleDisplay(clearMemory: true)
            return
        }

        // 暂停冻结：停止刷新、取消空闲清除，但不清空已有字幕。
        if !isPlaying {
            AppLogger.shared.log(.ui, "[Renderer] paused (isPlaying=false) — frozen, not clearing")
            idleClearTask?.cancel()
            translationTimeoutTask?.cancel()
            return
        }

        latencyManager.markInput()

        // 句子完成信号：新的 final 段出现。
        /// whisper：静音封口 → final 增加新段；Apple：引擎 final 修正/封口。
        /// 判据见 SubtitleSentenceTrigger（起点推进 or 文本变化）。
        /// 旧实现只比文本，导致同一会话里重复说同一句被永久静音。
        if let newest = final.last,
           sentenceTrigger.shouldTrigger(text: newest.text, start: newest.start) {
            lastSentenceFinalText = newest.text
            handleSentenceCompleted(newest.text)
            return
        }

        // 已完成句子的回声：静音封口后 pushState 把最后一段封口句当作
        // interim 推送，其文本与刚完成的句子相同——不作为新句渲染（否则
        // 旧句被当作正在说的新句反复重绘）。
        guard interimText != lastSentenceFinalText else { return }

        // 流式识别 → 标点/长度断句（停顿判定由 ASRManager VAD 负责）。
        switch detector.update(text: interimText) {
        case .recognized(let text):
            stream.recognitionText = text
            stream.subtitleState = .recognizing
            // 逐字 partial 节流：最小 0.2s 间隔重绘（与逐字入场动画配合，
            // 小步快更比大步慢更更平滑）。
            let now = Date()
            if now.timeIntervalSince(lastInterimRenderDate) >= 0.2 {
                lastInterimRenderDate = now
                renderText(text)
                scheduleIdleClear()
            }
        case .sentenceEnded(let sentence):
            handleSentenceCompleted(sentence)
        case .none:
            break
        }
    }

    /// 字幕行（final transcript / 已结束的识别段落）。
    struct SubtitleLine: Identifiable, Equatable {
        /// 唯一 key：同一行保留同一 id，避免 SplitText 重复播放。
        let id: String
        let text: String
        let translation: String?
        /// 该段在录制时间轴上的起点（秒）。用于「是否新句」判定：
        /// 封口推进时起点单调前移，比文本相同与否更可靠
        ///（见 lastHandledFinalStart）。
        let start: Double
        /// 历史行生命周期：visible → exiting → removed（退出只执行一次）。
        var status: HistoryStatus = .visible

        init(id: String, text: String, translation: String?, start: Double = 0,
             status: HistoryStatus = .visible) {
            self.id = id
            self.text = text
            self.translation = translation
            self.start = start
            self.status = status
        }
    }

    /// 历史行生命周期状态。
    enum HistoryStatus: Equatable {
        case visible
        case exiting
        case removed
    }

    /// 输入快照签名（final 各行 id/文本/译文 + interim）。
    private static func inputSignature(final: [SubtitleLine], interimText: String) -> String {
        final.map { "\($0.id)|\($0.text)|\($0.translation ?? "-")" }
            .joined(separator: "\u{1E}")
            + "\u{1D}" + interimText
    }

    /// 一句结束：去重 → 显示原文 → 触发整句翻译（只发一次 API）。
    private func handleSentenceCompleted(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 去重：近期相同句子不重复翻译/显示（防 ASR 重复输出）。
        guard sentenceDeduplicator.decide(trimmed) != .suppress else { return }
        sentenceDeduplicator.record(trimmed)

        // 显示原文，进入 Translating（不阻塞下一句）；清空上一句的译文区。
        // 最短停留：上一句显示不满 1.5s 时延迟顶替（防跳变闪读）。
        stream.recognitionText = trimmed
        stream.translationText = nil
        stream.showingTranslation = false
        stream.translationRenderer.clear()
        stream.subtitleState = .translating
        // 记录排队中的句子：译文早于源文上屏时用它挂起译文（见
        // flushDeferredTranslation）。直接渲染的分支会立即清掉。
        pendingSentenceText = trimmed
        // 上一句遗留的挂起译文作废（属于上一句，不该配到新句上）。
        deferredTranslation = nil
        renderSentenceWithMinDisplay(trimmed)
        // 记录本次翻译请求的句子：译文按此接收（Apple 引擎 partial 持续
        // 覆盖 recognitionText，不能用 recognitionText 校验译文归属）。
        streamingTranslationText = ""   // 新句子：重置流式译文累积
        lastTranslationRequestSource = trimmed
        onSentenceCompleted?(trimmed)
        scheduleTranslationTimeout()
        scheduleIdleClear()
    }

    /// 流式译文增量（LLM streaming）：累积渲染逐字上屏。
    @ObservationIgnored private var streamingTranslationText = ""
    @ObservationIgnored private var lastStreamRenderDate = Date.distantPast
    /// 句子最短停留：新句子替换显示后至少 1.5s 内不被下一句顶掉
    ///（过快更新排队等待，防字幕跳变闪读）。打字增长不受限（同句追加）。
    @ObservationIgnored private var sentenceShownAt = Date.distantPast
    @ObservationIgnored private var pendingSentenceTask: Task<Void, Never>?
    private static let minSentenceDisplay: TimeInterval = 1.5

    /// 句子级渲染（最短停留调度）：不满 1.5s 的新句子排队，到点渲染；
    /// 打字增长（同句追加）不受限。后到的句子顶掉排队中的前一句。
    private func renderSentenceWithMinDisplay(_ text: String) {
        pendingSentenceTask?.cancel()
        let now = Date()
        let elapsed = now.timeIntervalSince(sentenceShownAt)
        guard elapsed < Self.minSentenceDisplay else {
            sentenceShownAt = now
            renderText(text)
            flushDeferredTranslation()
            return
        }
        let wait = Self.minSentenceDisplay - elapsed
        pendingSentenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.sentenceShownAt = Date()
            self.renderText(text)
            self.flushDeferredTranslation()
        }
    }

    /// 排队等待渲染的句子文本（源文尚未上屏时的归属标记）。
    /// 译文早于源文到达时（译文 0.3s < 最短停留 1.5s），先挂起，
    /// 等 renderText 真正把源文画上去再渲染——否则会出现
    /// 「上一句的原文 + 下一句的译文」错配。
    @ObservationIgnored private var pendingSentenceText: String?
    /// 早到、等待源文上屏的译文。
    @ObservationIgnored private var deferredTranslation: (source: String, text: String)?

    /// 源文实际上屏后调用：补渲染期间早到的译文。
    private func flushDeferredTranslation() {
        pendingSentenceText = nil
        guard let deferred = deferredTranslation else { return }
        deferredTranslation = nil
        // 归属校验：译文对应的是当前正在显示的句子才渲染。
        guard deferred.source == lastTranslationRequestSource,
              !stream.renderer.text.isEmpty else { return }
        applyTranslationText(deferred.text)
    }

    /// 译文写入（原文保持不动，译文出现在下方译文区）。
    private func applyTranslationText(_ trimmed: String) {
        if trimmed.isEmpty || trimmed == lastTranslationRequestSource {
            stream.showingTranslation = false
            stream.translationText = nil
            stream.translationRenderer.clear()
        } else {
            stream.showingTranslation = true
            stream.translationText = trimmed
            renderTranslation(trimmed)
        }
        stream.subtitleState = .showing
        scheduleIdleClear()
    }

    /// 流式翻译增量入口（桥接层注入的 delta 回调）。
    /// 首个增量即进入「译文生长」显示态（不等完整响应）。
    func appendTranslationDelta(_ delta: String) {
        guard !delta.isEmpty, !stream.renderer.text.isEmpty else { return }
        guard stream.subtitleState != .showing else { return }   // 已定稿，丢弃迟到增量
        if streamingTranslationText.isEmpty {
            stream.showingTranslation = true
            stream.subtitleState = .translating
        }
        streamingTranslationText += delta
        // 有增量到达 = 翻译链路活着：把 3 秒超时重新计时。否则长译文在
        // 第 3 秒被超时打断（状态置 .showing → 下面的 delta 全被丢弃），
        // 整段译文要等最终结果才"跳"出来，流式效果完全失效。
        scheduleTranslationTimeout()
        let now = Date()
        if now.timeIntervalSince(lastStreamRenderDate) >= 0.12 {
            lastStreamRenderDate = now
            renderTranslation(streamingTranslationText)
        }
        scheduleIdleClear()
    }

    /// 翻译结果返回：原文保持显示，译文渲染到下方译文区（原文+译文同时显示）。
    /// 迟到容忍：只接受「最近一次翻译请求」的译文（新的一句已触发则丢弃，
    /// 避免串行）；显示已被空闲清除（画面为空）时同样丢弃，不让译文
    /// 在没有原文的空屏上单独冒出来。
    func setTranslationResult(for source: String, translation: String?) {
        streamingTranslationText = ""   // 流式定稿：重置增量状态
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty,
              trimmedSource == lastTranslationRequestSource else { return }
        let t = translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 源文还没上屏（该句仍在最短停留队列里）→ 不能立即渲染：否则会出现
        // 「上一句的原文 + 这一句的译文」错配，持续到 1.5s 后源文才切换。
        // 挂起，等 renderText 真正画上源文后由 flushDeferredTranslation 补渲。
        // pendingSentenceText 仅在排队窗口内非 nil（立即渲染的分支会清空）。
        if pendingSentenceText == trimmedSource {
            deferredTranslation = (trimmedSource, t)
            return
        }
        guard !stream.renderer.text.isEmpty else { return }
        latencyManager.markTranslated()
        PipelineLatencyStore.shared.recordTranslate(
            ms: Double(latencyManager.lastTranslationMs))
        applyTranslationText(t)
    }

    /// 单一渲染入口：断句（中文 30 / 英文 80）→ 渲染器（≤ maxLines 行，不省略）。
    /// 行数取设置页「字幕最大行数」（controls.maxLines）——此前原文/译文
    /// 都硬编码 2，导致该设置只改变窗口尺寸签名、不影响实际显示行数。
    /// 行数不变（同句增长/打字效果）时不加动画直接更新——每次 partial 都
    /// 重新起 0.18s 动画会在快速流式输出时产生抖动；只在换行数（1→2 行）
    /// 时用动画平滑过渡。
    private func renderText(_ text: String) {
        AppLogger.shared.log(.ui, "[Subtitle Display] render text=\(text.prefix(40))")
        let splitter = SubtitleSentenceSplitter()
        let limit = max(1, maxLines)
        let lines = Array(splitter.split(text, language: SubtitleLanguage.detect(text)).prefix(limit))
        stream.renderer.maxLines = limit
        if lines.count != stream.renderer.lines.count {
            _ = withAnimation(.easeOut(duration: 0.18)) {
                stream.renderer.setLines(lines)
            }
        } else {
            _ = stream.renderer.setLines(lines)
        }
        stream.subtitleText = stream.renderer.text
        latencyManager.markDisplayed()
        PipelineLatencyStore.shared.recordDisplay(
            ms: Double(latencyManager.lastTotalMs))
        // 只打渲染结果：ViewModel 不反向依赖窗口控制器（调试窗口状态
        // 由 OverlayController 自行打印）。
        AppLogger.shared.log(.ui, "[Subtitle Display] displayed=\(stream.renderer.text.prefix(40))")
    }

    /// 译文渲染入口：独立于原文渲染器（原文保持不动，译文出现在下方）。
    /// 行数同样取设置页「字幕最大行数」（此前硬编码 2）。
    private func renderTranslation(_ text: String) {
        let splitter = SubtitleSentenceSplitter()
        let lines = splitter.split(text, language: SubtitleLanguage.detect(text))
        let limit = max(1, maxLines)
        stream.translationRenderer.maxLines = limit
        _ = withAnimation(.easeOut(duration: 0.18)) {
            stream.translationRenderer.setLines(Array(lines.prefix(limit)))
        }
    }

    /// 字幕空闲自动清除：subtitleClearDelay 秒没有新的 ASR 输入 → 清空浮窗，
    /// 不显示「等待中 / 灰色文字 / 占位符」。只清画面不清记忆（见
    /// resetSubtitleDisplay）。
    private func scheduleIdleClear() {
        idleClearTask?.cancel()
        let delay = subtitleClearDelay
        idleClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isPlaying else { return }
            self.resetSubtitleDisplay(clearMemory: false)
        }
    }

    /// 翻译超时兜底：3 秒无**任何**结果只显示原文，不阻塞下一句。
    /// 注意是"无任何结果"——每收到一个流式增量都会重新计时
    ///（见 appendTranslationDelta），否则长译文会在第 3 秒被打断。
    private func scheduleTranslationTimeout() {
        translationTimeoutTask?.cancel()
        translationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.stream.subtitleState == .translating else { return }
            self.stream.subtitleState = .showing
            self.stream.showingTranslation = false
            self.stream.translationRenderer.clear()
            self.scheduleIdleClear()
        }
    }

    /// 清空浮窗字幕。
    /// - 空闲清除（`clearMemory: false`）：只清画面——去重/完成/翻译记忆
    ///   必须保留，否则静音轮询推送的同一句会被重新判为新句 → 渲染 →
    ///   再清除 → 周期性闪烁刷新；
    /// - 会话结束/清空（`clearMemory: true`）：画面 + 记忆全部重置
    ///   （新会话第一句不受上一会话末句影响）。
    private func resetSubtitleDisplay(clearMemory: Bool) {
        idleClearTask?.cancel()
        translationTimeoutTask?.cancel()
        // 排队中的句子任务必须一并取消：否则清屏后它到点触发 renderText，
        // 把上一句重新画到（已清空的）浮层上，且 idle-clear 受 isPlaying
        // 守卫不会再清掉它——停录/空闲清屏后字幕"诈尸"。
        pendingSentenceTask?.cancel()
        pendingSentenceTask = nil
        pendingSentenceText = nil
        deferredTranslation = nil
        if clearMemory {
            detector.reset()
            sentenceDeduplicator.reset()
            // 新会话必须清掉上一句的 final/翻译归属标记，否则新会话第一句与
            // 上一会话末句相同时会被误判为「已处理」，既不显示也不触发翻译。
            lastSentenceFinalText = ""
            sentenceTrigger.reset()
            lastTranslationRequestSource = ""
            lastProcessedInputSignature = nil
        }
        streamingTranslationText = ""
        lastStreamRenderDate = .distantPast
        latencyManager.reset()
        // 淡出清除：字幕/译文平滑消失，不做瞬间闪断。
        withAnimation(.easeOut(duration: 0.25)) {
            stream.renderer.clear()
            stream.translationRenderer.clear()
        }
        stream.recognitionText = ""
        stream.translationText = nil
        stream.showingTranslation = false
        stream.subtitleState = isPlaying ? .listening : .idle
        stream.subtitleText = ""
    }

    // MARK: - 工具方法

    /// 秒数格式化为 mm:ss。
    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
