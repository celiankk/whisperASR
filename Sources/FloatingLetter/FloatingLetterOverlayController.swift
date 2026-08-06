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

    /// 面板隐藏后仍保留最后位置，用于判断鼠标是否“移入浮层范围”。
    private var lastKnownFrame: NSRect = .zero
    private var isHidden = true
    /// 上一次轮询到的鼠标位置：只有位置发生变化（移动/移入）才视为操作，
    /// 避免鼠标停在浮层内时被反复“显示”。
    private var lastPointerPoint: NSPoint?

    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var hoverPollTask: Task<Void, Never>?
    private var frameObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var observationTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }

    private override init() {
        panel = FloatingLetterOverlayPanel(
            contentRect: NSRect(origin: .zero, size: FloatingLetterMetrics.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
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
        // 允许拖动整个长条浮层。
        panel.isMovableByWindowBackground = true
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

        // 拖动/缩放后更新 lastKnownFrame，隐藏时才能正确判断“移入范围”。
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncLastKnownFrame() }
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncLastKnownFrame() }
        }
    }

    // MARK: - 展示 / 关闭

    func present(viewModel: FloatingLetterViewModel) {
        self.viewModel = viewModel

        // 注入控制器关心的回调（窗口层级、淡出、关闭、紧凑切换）。
        viewModel.onIdleTimeout = { [weak self] in
            Task { @MainActor in self?.fadeOutAndHide() }
        }
        // 关闭按钮：销毁浮层窗口（业务层另有 onClosed 回调持久化偏好）。
        viewModel.onClose = { [weak self] in
            Task { @MainActor in self?.dismiss() }
        }
        viewModel.onCompactChanged = { [weak self] compact in
            Task { @MainActor in self?.applyCompact(compact) }
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
#if DEBUG
            FloatingLetterLeakState.hostingViewAlive += 1
#endif
            panel.contentView = hosting
            hostingView = hosting
        }

        // 屏幕右上角定位。
        placeAtTopRight(compact: viewModel.isCompact)

        isHidden = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        startMonitoring()
        observeViewModel()
        // 出现即开始 5 秒倒计时。
        viewModel.registerInteraction()
    }

    /// 销毁浮层：停止所有监听、取消轮询与观察、主动 invalidate 定时器。
    func dismiss() {
        stopMonitoring()
        observationTask?.cancel()
        observationTask = nil
        viewModel?.teardown()
        viewModel = nil

        isHidden = true
        lastPointerPoint = nil
        hostingView?.onMouseEnteredPanel = nil
        panel.contentView = nil
        hostingView = nil
        panel.orderOut(nil)
    }

    /// 重新定位到屏幕右上角（多显示器/位置漂移时可调用）。
    func resetPosition() {
        placeAtTopRight(compact: viewModel?.isCompact ?? false)
    }

    // MARK: - 定位

    /// 屏幕右上角定位：距屏幕右缘 20pt、距可见区顶缘 24pt。
    private func placeAtTopRight(compact: Bool) {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let size = compact
            ? FloatingLetterMetrics.compactSize
            : FloatingLetterMetrics.expandedSize
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
    private func applyCompact(_ compact: Bool) {
        let target = compact
            ? FloatingLetterMetrics.compactSize
            : FloatingLetterMetrics.expandedSize
        var frame = panel.frame
        let anchor = NSPoint(x: frame.maxX, y: frame.maxY)
        frame.size = target
        frame.origin = NSPoint(
            x: anchor.x - target.width,
            y: anchor.y - target.height
        )
        panel.setFrame(frame, display: true, animate: true)
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
        let region = panel.isVisible ? panel.frame : lastKnownFrame
        guard region.contains(point) else { return }
        showPanel()
        viewModel?.registerInteraction()
    }

    /// 鼠标移入（TrackingArea）：立即显示并重置倒计时。
    private func handlePointerEnter() {
        lastPointerPoint = NSEvent.mouseLocation
        showPanel()
        viewModel?.registerInteraction()
    }

    /// 轮询鼠标位置：仅当位置发生变化（移动/移入）时视为操作。
    private func handlePointerPosition(_ point: NSPoint) {
        defer { lastPointerPoint = point }
        let region = panel.isVisible ? panel.frame : lastKnownFrame
        guard region.contains(point), lastPointerPoint != point else { return }
        showPanel()
        viewModel?.registerInteraction()
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
    // 观察 isPinned：置顶开关变化时同步窗口层级（statusBar ↔ screenSaver）。

    private func observeViewModel() {
        observationTask?.cancel()
        guard viewModel != nil else { return }
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            withObservationTracking {
                _ = self.viewModel?.isPinned
            } onChange: {
                Task { @MainActor in
                    self.updateWindowLevel()
                    self.observeViewModel()
                }
            }
        }
        updateWindowLevel()
    }

    private func updateWindowLevel() {
        panel.level = (viewModel?.isPinned ?? false) ? .screenSaver : .statusBar
    }
}
