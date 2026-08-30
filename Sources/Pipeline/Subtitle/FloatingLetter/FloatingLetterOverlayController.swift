import AppKit
import SwiftUI
import Observation
import QuartzCore

// MARK: - 无边框、非激活浮层面板
//
// canBecomeKey/canBecomeMain 返回 false：浮层永远不抢焦点，方便
// 悬浮在其他应用窗口之上使用。

private final class FloatingLetterOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 带“鼠标移入”跟踪的 Hosting 视图
//
// 面板透明无边框，SwiftUI 内容通过 NSHostingView 承载。这里额外挂一个
// NSTrackingArea：鼠标进入浮层范围时立即显示并重置倒计时（.activeAlways
// 保证应用处于后台时也能收到进入事件）。

private final class FloatingLetterHostingView: NSHostingView<FloatingLetterContainerView> {
    var onMouseEnteredPanel: (() -> Void)?
    /// 背景按下：原生窗口拖动（performDrag）。
    var onBackgroundMouseDown: ((NSEvent) -> Void)?

    /// 系统 resize 热区宽度（窗口边缘/四角，与系统标准一致取 5pt，
    /// 透明全尺寸内容下视觉不可见——加宽到 8pt 提升可命中性）。
    private static let resizeHotEdge: CGFloat = 8

    /// 边缘/四角命中判定：命中区放行给系统 resize（styleMask .resizable
    /// 的原生处理），不再转发窗口拖动——此前 mouseDown 无条件走
    /// performDrag 把系统 resize 热区整个截走，边缘缩放形同虚设。
    private func isOnResizeEdge(_ event: NSEvent) -> Bool {
        let location = convert(event.locationInWindow, from: nil)
        let bounds = bounds
        let e = Self.resizeHotEdge
        let nearLeft = location.x <= e
        let nearRight = location.x >= bounds.maxX - e
        let nearBottom = location.y <= e
        let nearTop = location.y >= bounds.maxY - e
        return nearLeft || nearRight || nearBottom || nearTop
    }

    deinit {
#if DEBUG
        FloatingLetterLeakState.hostingViewAlive -= 1
        print("[FloatingLetter] HostingView deinit, alive=\(FloatingLetterLeakState.hostingViewAlive)")
#endif
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnteredPanel?()
    }

    override func mouseDown(with event: NSEvent) {
        // 内部区域：转发窗口拖动。边缘区 hitTest 已返回 nil（见下），
        // 事件直接落窗口原生 resize，不会进入本方法。
        onBackgroundMouseDown?(event)
    }

    /// 边缘/四角让路：hitTest 返回 nil → 事件穿透到窗口层（NSThemeFrame），
    /// 由系统原生 resize 接管（styleMask .resizable）。这是透明全尺寸内容
    /// 窗口让出 resize 热区的标准做法——拦截 mouseDown 再转发是不成立的
    /// （NSView.mouseDown 默认实现不会触发窗口缩放）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown,
           isOnResizeEdge(event) {
            return nil
        }
        return super.hitTest(point)
    }
}

// MARK: - 浮层控制器
//
// 职责：
// 1. 创建/管理无边框 NSPanel：窗口置顶（.statusBar，置顶后 .screenSaver）、
//    屏幕右上角定位、允许拖动；
// 2. 全局 + 本地事件监听：鼠标移入浮层范围立即显示并重置倒计时，点击浮层内
//    任意控件重置倒计时；
// 3. 5 秒闲置后淡出隐藏，移入时淡入显示；
// 4. 销毁时停止所有监听、取消轮询 Task、主动 invalidate ViewModel 定时器。

@MainActor
final class FloatingLetterOverlayController: NSObject {
    static let shared = FloatingLetterOverlayController()

    /// 隐藏态轮询间隔：面板 orderOut 后靠轮询鼠标位置实现“移入即显示”。
    private static let hoverPollInterval: TimeInterval = 0.25

    private let panel: FloatingLetterOverlayPanel
    private var hostingView: FloatingLetterHostingView?
    private var viewModel: FloatingLetterViewModel?
    /// 字幕窗口状态统一管理（frame / mode / mouse / editState）。
    private let windowManager = SubtitleWindowManager()

    /// 面板隐藏后仍保留最后位置，用于判断鼠标是否“移入浮层范围”。
    private var lastKnownFrame: NSRect = .zero
    private var isHidden = true
    /// 上一次轮询到的鼠标位置：只有位置发生变化（移动/移入）才视为操作，
    /// 避免鼠标停在浮层内时被反复“显示”。
    private var lastPointerPoint: NSPoint?

    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var hoverPollTask: Task<Void, Never>?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var liveResizeEndObserver: NSObjectProtocol?
    private var observationTask: Task<Void, Never>?
    /// 窗口状态持久化键（窗口尺寸/原点）。
    private enum FrameKeys {
        static let width = "subtitleWindowWidth"
        static let height = "subtitleWindowHeight"
        static let originX = "subtitleWindowX"
        static let originY = "subtitleWindowY"
    }
    /// 穿透模式：指针是否仍在字幕区域（3 秒停留显示控制栏）。
    private var passthroughPointerInside = false
    /// 穿透模式悬停任务（显示/隐藏控制栏）。
    private var passthroughHoverTask: Task<Void, Never>?
    /// 穿透模式控制栏显示后的 5 秒隐藏任务。
    private var passthroughControlsHideTask: Task<Void, Never>?
    /// 最近一次已保存的窗口帧（避免 move/resize 高频写 UserDefaults）。
    private var lastSavedFrame: NSRect?

    var isVisible: Bool { panel.isVisible }

    /// 浮窗 frame（可见时；分区条带判定用——NSRect 无私有类型问题）。
    var visiblePanelFrame: NSRect? {
        panel.isVisible ? panel.frame : nil
    }
    /// 字幕浮层当前区域（选择弹窗判断“空白处返回”时排除浮层本身）。
    var overlayFrame: NSRect? { panel.isVisible ? panel.frame : nil }

    /// 排查日志：窗口关键状态快照。
    var debugStateDescription: String {
        let frame = panel.isVisible ? NSStringFromRect(panel.frame) : "hidden"
        return "visible=\(panel.isVisible) hidden=\(isHidden) "
            + "alpha=\(String(format: "%.2f", panel.alphaValue)) "
            + "mouseThrough=\(panel.ignoresMouseEvents) frame=\(frame)"
    }

    private override init() {
        panel = FloatingLetterOverlayPanel(
            contentRect: NSRect(origin: .zero, size: FloatingLetterMetrics.expandedSize),
            // 透明标题栏 + 全尺寸内容：视觉与 borderless 一致，但保留系统
            // 原生的边缘/四角缩放（系统光标、系统手势）与原生窗口行为。
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    // MARK: - 面板配置

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 窗口置顶：默认 statusBar 层级（高于普通窗口）；图钉置顶后升到 screenSaver。
        panel.level = .statusBar
        // 普通模式鼠标穿透；拖动仅在编辑模式开启。
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 在所有 Space 上悬浮、全屏辅助窗口、不参与循环切换。
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .utilityWindow
        // 隐藏标题栏与标准窗口按钮（保持无边框观感）。
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // 原生 live-resize 结束：一次性落盘窗口帧 + 锁尺寸签名。
        liveResizeEndObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleNativeResizeEnded() }
        }

        // 窗口移动/缩放统一走 windowFrameChanged（单向流：Window → 状态 → UI）。
        // 高频通知（didResize 跟随原生 resize 每帧触发）通过 frameSyncBox 合并：
        // 任意时刻最多只有一个排队中的同步任务，不随事件数产生 Task 风暴。
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.requestFrameSync()
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.requestFrameSync()
        }
    }

    /// 帧同步合并盒：通知闭包（非隔离上下文）只翻转标志位，
    /// 真正的工作最多排队一个 MainActor 任务。
    private final class FrameSyncBox: @unchecked Sendable {
        var pending = false
    }

    private nonisolated let frameSyncBox = FrameSyncBox()

    private nonisolated func requestFrameSync() {
        guard !frameSyncBox.pending else { return }
        frameSyncBox.pending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.frameSyncBox.pending = false
            self.windowFrameChanged()
        }
    }

    // MARK: - 展示 / 关闭

    func present(viewModel: FloatingLetterViewModel) {
        self.viewModel = viewModel

        // 注入控制器关心的回调（窗口层级、控制层隐藏、关闭、紧凑切换）。
        viewModel.onIdleTimeout = { [weak self] in
            // 5 秒无操作：只隐藏控制层（ControlLayer），字幕层保持显示。
            Task { @MainActor in
                self?.viewModel?.controlVisibility = .hidden
            }
        }
        // 关闭按钮：销毁浮层窗口（业务层另有 onClosed 回调持久化偏好）。
        viewModel.onClose = { [weak self] in
            Task { @MainActor in self?.dismiss() }
        }
        viewModel.onMousePassthroughChanged = { [weak self] _ in
            Task { @MainActor in
                self?.passthroughHoverTask?.cancel()
                self?.passthroughControlsHideTask?.cancel()
                self?.applyWindowMode()
            }
        }
        let root = FloatingLetterContainerView(viewModel: viewModel)
        if let hostingView {
            hostingView.rootView = root
        } else {
            let hosting = FloatingLetterHostingView(rootView: root)
            hosting.autoresizingMask = [.width, .height]
            hosting.onMouseEnteredPanel = { [weak self] in
                Task { @MainActor in self?.handlePointerEnter() }
            }
            hosting.onBackgroundMouseDown = { [weak self] event in
                Task { @MainActor in self?.handleBackgroundMouseDown(event) }
            }
#if DEBUG
            FloatingLetterLeakState.hostingViewAlive += 1
#endif
            panel.contentView = hosting
            hostingView = hosting
        }

        // 恢复上次窗口位置/大小；无有效记录时屏幕右上角定位。
        if !restoreWindowFrameIfAvailable() {
            placeAtTopRight()
        }
        // 重置观察签名，保证重新 present 时完整同步一次窗口状态。
        lastAppliedPin = nil
        lastAppliedSizeSignature = nil
        lastAppliedModeSignature = nil
        applyInteractiveDefaults()
        applyWindowMode()

        isHidden = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        startMonitoring()
        observeViewModel()
        // 出现即开始 5 秒倒计时。
        viewModel.registerInteraction()
        AppLogger.shared.log(.window, "Overlay presented frame=\(NSStringFromRect(panel.frame))")
    }

    /// 菜单栏快捷切换鼠标穿透（MenuBarController 入口）。
    func togglePassthroughFromMenu() {
        guard let viewModel else { return }
        viewModel.toggleMousePassthrough()
    }

    /// 销毁浮层：停止所有监听、取消轮询与观察、主动 invalidate 定时器。
    func dismiss() {
        // 防御：先停止窗口拖动与鼠标事件接收再 orderOut——避免窗口在
        // 系统鼠标跟踪会话（拖动/缩放）进行中消失，残留全局鼠标抓取
        // （表现为鼠标卡住、点击无响应）。
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        stopMonitoring()
        observationTask?.cancel()
        observationTask = nil
        // 穿透悬停/控制栏隐藏任务与 resize 显示链接一并释放
        //（关闭窗口的瞬间可能正处于悬停计时或拖拽中）。
        passthroughHoverTask?.cancel()
        passthroughHoverTask = nil
        passthroughControlsHideTask?.cancel()
        passthroughControlsHideTask = nil
        saveWindowFrame()
        windowManager.reset()
        viewModel?.teardown()
        viewModel = nil

        isHidden = true
        lastPointerPoint = nil
        lastAppliedPin = nil
        lastAppliedSizeSignature = nil
        lastAppliedModeSignature = nil
        hostingView?.onMouseEnteredPanel = nil
        panel.contentView = nil
        hostingView = nil
        panel.orderOut(nil)
        // 若选择弹窗还开着（例如通过浮层 X 关闭），一并收起。
        FloatingAppPickerController.shared.dismiss()
        AppLogger.shared.log(.window, "Overlay dismissed")
    }

    /// 重新定位到屏幕右上角（多显示器/位置漂移时可调用）。
    func resetPosition() {
        placeAtTopRight()
    }

    // MARK: - 定位

    /// 按当前模式返回目标尺寸：展开 > 紧凑。
    private var targetSize: CGSize {
        guard let viewModel else { return FloatingLetterMetrics.expandedSize }
        if viewModel.isCompact {
            return FloatingLetterMetrics.compactSize
        }
        // 窗口尺寸完全由 SubtitleContainerConfig 决定（与字号解耦）：
        // 调整字号不会改变窗口大小；容器宽度/高度独立调整。
        // 上限与容器钳制一致（4000/2160）：用户拖拽出的尺寸不会被
        // targetSize 二次截断（否则设置变更会意外缩小窗口）。
        let chrome: CGFloat = 20 + 4 + 30 + 18
        let contentHeight = viewModel.requiredSubtitleHeight
        let height = min(max(chrome + contentHeight, 172), 2232)
        let width = min(viewModel.subtitleContainerWidth + 48, 4048)
        return CGSize(width: width, height: height)
    }

    /// 屏幕右上角定位：距屏幕右缘 20pt、距可见区顶缘 24pt。
    private func placeAtTopRight() {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let size = targetSize
        // 小屏幕兜底：不超出可见区域。
        let width = min(size.width, visible.width - 40)
        let height = min(size.height, visible.height - 40)
        let origin = NSPoint(
            x: visible.maxX - width - 20,
            y: visible.maxY - height - 24
        )
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.setFrame(frame, display: true)
        lastKnownFrame = frame
    }

    /// 紧凑/展开切换：锚定右上角缩放窗口。
    private func applyPanelSize() {
        let target = targetSize
        var frame = panel.frame
        let anchor = NSPoint(x: frame.maxX, y: frame.maxY)
        frame.size = target
        frame.origin = NSPoint(
            x: anchor.x - target.width,
            y: anchor.y - target.height
        )
        // 2pt 容差：避免模式切换/取整造成的微缩放累积（窗口反复变大）。
        guard abs(frame.width - panel.frame.width) > 2
            || abs(frame.height - panel.frame.height) > 2 else { return }
        // 不用动画缩放：动画帧变化会触发 NSHostingView 安全区/约束重入，
        // 在 macOS 26 上会导致显示周期约束更新崩溃（详见 newdme 第十三节）。
        panel.setFrame(frame, display: true)
        lastKnownFrame = frame
    }

    private func syncLastKnownFrame() {
        lastKnownFrame = panel.frame
    }

    // MARK: - 事件监听
    //
    // 三层监听覆盖所有激活场景：
    // 1. 本地点击监听：应用自身（包括浮层内控件）的点击；
    // 2. 全局点击监听：其他应用前台时的点击；
    // 3. 轮询 Task：面板隐藏（orderOut）后，周期性检查鼠标位置，
    //    实现“鼠标移入浮层范围立即显示”。

    private func startMonitoring() {
        stopMonitoring()

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleClick(at: NSEvent.mouseLocation)
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleClick(at: NSEvent.mouseLocation)
            }
        }

        hoverPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.hoverPollInterval))
                guard let self else { continue }
                self.handlePointerPosition(NSEvent.mouseLocation)
            }
        }
    }

    private func stopMonitoring() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        localClickMonitor = nil
        globalClickMonitor = nil
        hoverPollTask?.cancel()
        hoverPollTask = nil
    }

    /// 点击浮层范围：立即显示并重置 5 秒倒计时。
    private func handleClick(at point: NSPoint) {
        guard viewModel?.mousePassthrough == false else { return }
        let region = panel.isVisible ? panel.frame : lastKnownFrame
        if region.contains(point) {
            showPanel()
            viewModel?.registerInteraction()
        }
    }

    /// 鼠标移入（TrackingArea）：立即显示并重置倒计时。
    private func handlePointerEnter() {
        guard viewModel?.mousePassthrough == false else { return }
        lastPointerPoint = NSEvent.mouseLocation
        showPanel()
        viewModel?.registerInteraction()
    }

    /// 轮询鼠标位置：
    /// - 普通/编辑模式：位置变化即视为操作（显示控件、重置计时）；
    /// - 穿透模式：仅做停留检测（3 秒显示控制栏），不触发普通 hover。
    private func handlePointerPosition(_ point: NSPoint) {
        defer { lastPointerPoint = point }
        let region = panel.isVisible ? panel.frame : lastKnownFrame
        let inside = region.contains(point)

        if viewModel?.mousePassthrough == true {
            handlePassthroughHover(inside: inside)
            return
        }
        guard inside, lastPointerPoint != point else { return }
        showPanel()
        viewModel?.registerInteraction()
    }

    /// 光标是否在浮窗底部功能区条带（全局屏幕坐标）。
    private static func isInControlsBand(point: NSPoint) -> Bool {
        guard let frame = FloatingLetterOverlayController.shared.visiblePanelFrame else { return false }
        let bandHeight: CGFloat = 44
        return point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.minY + bandHeight
    }

    /// 穿透模式停留检测：进入 3 秒 → 显示控制栏（临时可交互，仅控制层可点）；
    /// 离开 1.5 秒 → 隐藏控制栏并恢复穿透。
    private func handlePassthroughHover(inside: Bool) {
        passthroughHoverTask?.cancel()
        passthroughControlsHideTask?.cancel()
        passthroughPointerInside = inside

        if inside {
            guard viewModel?.controlVisibility != .visible else { return }
            // 分区快速呼出：光标位于底部功能区条带（~44pt）→ 立即呼出
            /// 控制栏可交互（想操作的人直接把鼠标移到底部，无需等 3 秒）；
            /// 停留在字幕主体 → 维持 3 秒停留判定。
            if Self.isInControlsBand(point: NSEvent.mouseLocation) {
                showPassthroughControls()
                return
            }
            passthroughHoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let vm = self.viewModel,
                      vm.mousePassthrough, self.passthroughPointerInside else { return }
                self.showPassthroughControls()
            }
        } else {
            passthroughHoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, let vm = self.viewModel,
                      vm.mousePassthrough, !self.passthroughPointerInside else { return }
                self.hidePassthroughControls()
            }
        }
    }

    /// 穿透模式：显示控制栏（窗口临时接收鼠标，仅控制层可点击）。
    private func showPassthroughControls() {
        guard let viewModel, viewModel.mousePassthrough else { return }
        viewModel.controlVisibility = .visible
        panel.ignoresMouseEvents = false
        // 控制栏显示 5 秒无操作后自动隐藏（恢复穿透）。
        passthroughControlsHideTask?.cancel()
        passthroughControlsHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let vm = self.viewModel,
                  vm.mousePassthrough, self.passthroughPointerInside else { return }
            self.hidePassthroughControls()
        }
    }

    /// 穿透模式：隐藏控制栏并恢复完全穿透。
    private func hidePassthroughControls() {
        guard let viewModel, viewModel.mousePassthrough else { return }
        viewModel.controlVisibility = .hidden
        panel.ignoresMouseEvents = true
        passthroughControlsHideTask?.cancel()
    }

    // MARK: - 淡入淡出

    /// 淡出隐藏：5 秒无操作后调用。
    private func fadeOutAndHide() {
        guard panel.isVisible, !isHidden else { return }
        isHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FloatingLetterMetrics.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.isHidden else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// 淡入显示：鼠标移入/点击时调用。
    private func showPanel() {
        isHidden = false
        guard !panel.isVisible || panel.alphaValue < 0.99 else { return }

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FloatingLetterMetrics.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().alphaValue = 1
        }
    }

    // MARK: - ViewModel 观察
    //
    // 单向流：UI 状态 → 窗口。防循环策略——按职责拆分签名，只有真正影响
    // 窗口的字段变化才触发对应操作（hover 引起的 controlVisibility 翻转
    // 不再触发尺寸重算；尺寸重算前做 2pt 容差与拖拽中跳过，杜绝
    // Window → 状态 → UI → Window 反馈环）。

    /// 上次已应用的置顶状态（nil = 未应用过）。
    private var lastAppliedPin: Bool?
    /// 上次已应用的尺寸签名（isCompact / maxLines / requiredSubtitleHeight）。
    private var lastAppliedSizeSignature: Int?
    /// 上次已应用的模式签名（mousePassthrough / controlVisibility）。
    private var lastAppliedModeSignature: Int?

    private func observeViewModel() {
        observationTask?.cancel()
        guard viewModel != nil else { return }
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            withObservationTracking {
                _ = self.viewModel?.isPinned
                _ = self.viewModel?.isCompact
                _ = self.viewModel?.maxLines
                _ = self.viewModel?.requiredSubtitleHeight
                _ = self.viewModel?.controlVisibility
                _ = self.viewModel?.mousePassthrough
            } onChange: {
                Task { @MainActor in
                    self.applyObservedWindowState()
                    self.observeViewModel()
                }
            }
        }
        // 初次观察立即同步一次（层级 / 模式 / 尺寸）。
        applyObservedWindowState()
    }

    /// 尺寸签名：只有这三个字段才允许驱动窗口尺寸变化。
    private func sizeSignature(for viewModel: FloatingLetterViewModel) -> Int {
        var hasher = Hasher()
        hasher.combine(viewModel.isCompact)
        hasher.combine(viewModel.maxLines)
        hasher.combine(viewModel.requiredSubtitleHeight)
        return hasher.finalize()
    }

    /// 按签名选择性应用窗口状态：与上次相同的部分完全跳过。
    private func applyObservedWindowState() {
        guard let viewModel else { return }

        if lastAppliedPin != viewModel.isPinned {
            lastAppliedPin = viewModel.isPinned
            updateWindowLevel()
        }

        var modeHasher = Hasher()
        modeHasher.combine(viewModel.mousePassthrough)
        modeHasher.combine(viewModel.controlVisibility)
        let modeSig = modeHasher.finalize()
        if lastAppliedModeSignature != modeSig {
            lastAppliedModeSignature = modeSig
            applyWindowMode()
        }

        let sizeSig = sizeSignature(for: viewModel)
        if lastAppliedSizeSignature != sizeSig {
            lastAppliedSizeSignature = sizeSig
            // 穿透模式 / resize 拖拽中：窗口由原生驱动，不参与自动尺寸计算。
            if !viewModel.mousePassthrough {
                applyPanelSize()
            }
        }
    }

    // MARK: - 窗口模式（唯一默认交互态 / 鼠标穿透）

    /// 默认启动即“编辑模式”能力：窗口始终可移动、可左上角缩放、显示编辑边框。
    /// 只保留两种运行时状态：interactive（默认）与 passthrough（↗ 切换）。
    private func applyInteractiveDefaults() {
        panel.styleMask.insert(.resizable)
        panel.isMovableByWindowBackground = true
        // 与容器最小值（400×100 + chrome）对齐：窗口不可能小于容器，
        // 杜绝“缩到 300×80 后容器钳制回弹”的尺寸打架。
        panel.minSize = NSSize(width: 448, height: 172)
        viewModel?.controlVisibility = .visible
    }

    /// 两态窗口模式：
    /// - passthrough：控制栏隐藏时 ignoresMouseEvents = true（停留 3 秒呼出控制栏）；
    /// - interactive：可交互、可拖动、可缩放。
    private func applyWindowMode() {
        guard let viewModel else { return }
        if viewModel.mousePassthrough {
            windowManager.setPassthrough(true)
            panel.isMovableByWindowBackground = false
            panel.styleMask.remove(.resizable)
            // 穿透态：控制栏隐藏时才忽略鼠标（停留 3 秒显示控制栏时临时可交互）。
            if viewModel.controlVisibility == .hidden {
                panel.ignoresMouseEvents = true
            }
        } else {
            windowManager.setPassthrough(false)
            panel.ignoresMouseEvents = false
            panel.isMovableByWindowBackground = true
            panel.styleMask.insert(.resizable)
        }
        AppLogger.shared.log(.window, "Window mode=\(windowManager.mode) passthrough=\(viewModel.mousePassthrough)")
    }

    /// 窗口移动/缩放回调：更新 currentFrame 并保存；
    /// 原生 live-resize 拖拽中每帧同步容器（字幕实时重排），帧落盘留到
    /// didEndLiveResize 一次性完成（避免拖拽中高频写 UserDefaults）。
    private func windowFrameChanged() {
        syncLastKnownFrame()
        windowManager.markFrame(panel.frame)
        syncContainerFromWindowFrame()
        if !panel.inLiveResize {
            saveWindowFrame()
        }
    }

    /// 原生缩放结束：落盘窗口帧并锁尺寸签名（防止随后的状态观察用容器
    /// 配置反推 targetSize 把窗口弹回——容器钳制与窗口尺寸不一致时会跳）。
    private func handleNativeResizeEnded() {
        saveWindowFrame()
        if let viewModel {
            lastAppliedSizeSignature = sizeSignature(for: viewModel)
        }
        AppLogger.shared.log(.window, "Native resize end frame=\(NSStringFromRect(panel.frame))")
    }

    /// 把当前窗口内容尺寸映射为容器配置（容器始终填满内容区）。
    /// 上限放宽到 4000/2160：窗口是尺寸的唯一事实来源，容器配置只做镜像，
    /// 不再把用户拖出的合法大窗口截断到设置滑杆的 UI 范围。
    private func syncContainerFromWindowFrame() {
        guard let viewModel else { return }
        let width = max(400, min(panel.frame.width - 48, 4000))
        let height = max(100, min(panel.frame.height - 72, 2160))
        viewModel.adjustSubtitleContainer(width: width, height: height)
    }

    /// 背景按下：原生窗口拖动（Finder 式，窗口整体跟随指针）。
    /// 边缘/四角缩放由系统原生处理，不经过本方法。
    private func handleBackgroundMouseDown(_ event: NSEvent) {
        panel.performDrag(with: event)
    }

    /// 保存窗口尺寸/原点（重新打开 App 恢复）。
    private func saveWindowFrame() {
        let frame = panel.frame
        // 阈值去抖：帧变化 <0.5pt 不重复写（避免高频拖动刷 UserDefaults）。
        if let last = lastSavedFrame,
           abs(frame.width - last.width) < 0.5,
           abs(frame.height - last.height) < 0.5,
           abs(frame.origin.x - last.origin.x) < 0.5,
           abs(frame.origin.y - last.origin.y) < 0.5 {
            return
        }
        lastSavedFrame = frame
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.width), forKey: FrameKeys.width)
        defaults.set(Double(frame.height), forKey: FrameKeys.height)
        defaults.set(Double(frame.origin.x), forKey: FrameKeys.originX)
        defaults.set(Double(frame.origin.y), forKey: FrameKeys.originY)
    }

    /// 恢复上次窗口位置/大小；无效（过小/移出屏幕）返回 false。
    private func restoreWindowFrameIfAvailable() -> Bool {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: FrameKeys.width)
        let height = defaults.double(forKey: FrameKeys.height)
        let originX = defaults.double(forKey: FrameKeys.originX)
        let originY = defaults.double(forKey: FrameKeys.originY)
        guard width >= 300, height >= 80 else { return false }
        let screenFrame = NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: originX, y: originY, width: width, height: height)
        guard screenFrame.intersects(frame) else { return false }
        panel.setFrame(frame, display: false)
        lastKnownFrame = frame
        return true
    }

    private func updateWindowLevel() {
        panel.level = (viewModel?.isPinned ?? false) ? .screenSaver : .statusBar
    }
}
