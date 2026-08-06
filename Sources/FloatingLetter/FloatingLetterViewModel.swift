import Foundation
import Observation
import CoreGraphics

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

    /// 当前主字幕行（白 100%）：最新在尾部，最多 2 行，使用 SplitText 字符入场。
    var currentLines: [SubtitleLine] = []
    /// 历史字幕行（灰 30%）：位于主字幕后方，只占 maxLines 剩余空间，
    /// 超出容量后从最旧开始逐行退出（visible → exiting → removed）。
    var historyLines: [SubtitleLine] = []
    /// 是否正在播放（录制 + 实时转录中）。暂停/停止时冻结历史字幕，
    /// 不创建新的退出计时器、不重复触发动画。
    var isPlaying = false
    /// 当前流式识别中的临时文本（interim，普通文本直出，不进入历史、不触发 SplitText）。
    var interimText = ""
    /// 临时文本对应的译文。
    var interimTranslation: String?
    /// 最大显示行数（1–3，默认 2，由设置页同步）。
    var maxLines = 2

    /// 历史字幕逐行退出任务（每条 0.45s，最旧优先）。
    @ObservationIgnored private var historyExitTask: Task<Void, Never>?
    /// 已完成“退出→移除”生命周期的字幕 id：同一条字幕不允许再次进入历史行，
    /// 这是修复“退出动画无限循环”的关键（状态锁）。
    @ObservationIgnored private var spentHistoryIDs: Set<String> = []

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
    var includeMicrophone = false
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

    // MARK: 样式（由设置页同步，保持旧设置项继续生效）

    /// 原文（主字幕）字号。
    var sourceFontSize: CGFloat = 17
    /// 译文字号。
    var translationFontSize: CGFloat = 13
    /// 边框不透明度。
    var borderOpacity: Double = 0.1

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
        historyExitTask?.cancel()
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
            if let translation = nonEmptyTranslation {
                return translation
            }
            return subtitleTextVisible ? "等待翻译…" : "字幕已隐藏"
        }
        if subtitleTextVisible {
            return subtitleText.isEmpty ? "字幕浮层已就绪" : subtitleText
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
        historyExitTask?.cancel()
    }

    // MARK: - 闲置自动隐藏计时器

    /// 任意交互（点击、鼠标移动、进入浮层）后调用，重置 5 秒倒计时。
    func registerInteraction() {
        resetIdleTimer()
    }

    private func resetIdleTimer() {
        invalidateIdleTimer()
        // 选择应用阶段不自动隐藏（用户可能正在浏览应用列表）。
        guard autoHideEnabled, !isTornDown, !isSelectingApp else { return }
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleHideAfter,
            repeats: false
        ) { [weak self] _ in
            guard let self, !self.isTornDown else { return }
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

    // MARK: - 字幕队列更新

    /// 当前主字幕容量（maxLines=1 时 1 行，否则最多 2 行）。
    private var currentCapacity: Int {
        maxLines == 1 ? 1 : 2
    }

    /// 历史字幕容量：maxLines 剩余空间（优先保证当前字幕）。
    private var historyCapacity: Int {
        max(0, maxLines - currentCapacity)
    }

    /// 字幕容器所需高度（按“行数 × 行高 + 行间距”计算，供浮框自适应）。
    var requiredSubtitleHeight: CGFloat {
        let lineCount = currentLines.count + historyLines.count + (interimText.isEmpty ? 0 : 1)
        let hasTranslation = currentLines.contains { $0.translation != nil }
            || historyLines.contains { $0.translation != nil }
            || interimTranslation != nil
        let lineUnit = sourceFontSize * 1.22
            + (hasTranslation ? translationFontSize * 1.15 : 0)
        return CGFloat(max(1, lineCount)) * lineUnit
            + CGFloat(max(0, lineCount - 1)) * 3
    }

    /// 由桥接层在每次识别快照变化时调用：
    /// - interim：流式临时句，普通文本直出，不进历史、不触发动画；
    /// - final：最新句进入 currentLines（白 100%，SplitText 字符动画），
    ///   更早的句进入 historyLines（灰 30%），只占 maxLines 剩余空间；
    /// - 超出容量的历史行从最旧开始逐行退出（visible → exiting → removed）。
    func updateSubtitleState(
        final: [SubtitleLine],
        interimText: String,
        interimTranslation: String?,
        isPlaying: Bool
    ) {
        self.isPlaying = isPlaying

        // 录制结束/清空：全部清空。
        if final.isEmpty, interimText.isEmpty {
            historyExitTask?.cancel()
            spentHistoryIDs.removeAll()
            currentLines = []
            historyLines = []
            self.interimText = ""
            self.interimTranslation = nil
            subtitleText = ""
            translationText = nil
            return
        }

        // 暂停冻结：不更新行、不启动任何动画、不重算布局。
        // 保持当前字幕 DOM/布局状态；恢复播放后由下一次推送重新接管。
        if !isPlaying {
            historyExitTask?.cancel()
            return
        }

        let hasInterim = !interimText.isEmpty
        let currentFinalsCapacity = max(0, currentCapacity - (hasInterim ? 1 : 0))
        let historyCapacity = self.historyCapacity

        // 当前行：最新的 currentFinalsCapacity 条 final。
        let currentFinals = Array(final.suffix(currentFinalsCapacity))
        // 历史候选：当前行之前、最新的 historyCapacity 条 final。
        let historyCandidates: [SubtitleLine] = final.count > currentFinalsCapacity
            ? Array(final.prefix(final.count - currentFinalsCapacity).suffix(historyCapacity))
            : []

        self.interimText = interimText
        self.interimTranslation = interimTranslation
        self.currentLines = currentFinals

        reconcileHistory(
            candidates: historyCandidates,
            candidateIDs: Set(historyCandidates.map(\.id)),
            isPlaying: isPlaying
        )

        // 兼容旧接口（compact 药丸 / 占位逻辑仍读 subtitleText）。
        subtitleText = hasInterim ? interimText : (currentLines.last?.text ?? "")
        translationText = hasInterim ? interimTranslation : currentLines.last?.translation
    }

    /// 合并历史行：保留仍在候选中的行（id 稳定），新候选追加（visible），
    /// 超出候选的行从最旧开始逐行 exiting → removed，退出只执行一次。
    private func reconcileHistory(
        candidates: [SubtitleLine],
        candidateIDs: Set<String>,
        isPlaying: Bool
    ) {
        // 清理已 removed 的行。
        historyLines.removeAll { $0.status == .removed }

        // 合并：保留旧行（同 id 不重播），追加新候选。
        var merged = historyLines
        let existingIDs = Set(merged.map(\.id))
        // 已完成生命周期的 id 不再重新进入历史行（防循环/防重复动画）。
        for line in candidates
            where !existingIDs.contains(line.id) && !spentHistoryIDs.contains(line.id) {
            merged.append(line)
        }
        // 仍在候选中的旧行保持 visible（状态锁：不会重复退出）。
        for index in merged.indices where candidateIDs.contains(merged[index].id) {
            merged[index].status = .visible
        }
        historyLines = merged

        // 逐行退出：不在候选且仍 visible 的行，最旧优先。
        historyExitTask?.cancel()
        guard isPlaying else { return }
        let exitingIDs = historyLines
            // 包含正在 exiting 的行：中途更新后仍需完成移除。
            .filter { !candidateIDs.contains($0.id) && $0.status != .removed }
            .map(\.id)
        guard !exitingIDs.isEmpty else { return }

        historyExitTask = Task { @MainActor [weak self] in
            for id in exitingIDs {
                guard let self, !Task.isCancelled, self.isPlaying else { return }
                // 状态锁：visible → exiting 只允许一次。
                if let index = self.historyLines.firstIndex(where: { $0.id == id }),
                   self.historyLines[index].status == .visible {
                    self.historyLines[index].status = .exiting
                }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self.historyLines.removeAll { $0.id == id }
                self.spentHistoryIDs.insert(id)
            }
        }
    }

    // MARK: - 工具方法

    /// 秒数格式化为 mm:ss。
    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
