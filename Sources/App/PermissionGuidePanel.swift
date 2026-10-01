import AppKit
import SwiftUI

// MARK: - 悬浮授权引导面板（PermissionGuidePanelController）
//
// 对标 ZCode 的「附着在系统设置下方」授权窗：一个置顶、不抢焦点的小
// 浮窗，用户点「打开系统设置」后仍悬浮在系统设置之上——直接从浮窗把
// app 图标拖进系统设置的权限列表，松手即授权，拖完关掉浮窗。
//
// 关键点：
// - NSPanel + .nonactivatingPanel：从浮窗拖拽不会把 WhisperASR 调到
//   前台（否则系统设置被挤到后面，列表看不见）；
// - level .floating：悬浮在系统设置（.normal）之上；
// - 拖拽数据用 NSItemProvider(contentsOf:)（Finder 同款注册，
//   系统设置的 TCC 列表接受 .app 的 file URL 拖入）。

/// 悬浮窗的贴附状态（CGWindowList 轮询结果 → SwiftUI 内容）。
@Observable
@MainActor
final class PermissionGuideModel {
    var attached = false
}

@MainActor
final class PermissionGuidePanelController {
    static let shared = PermissionGuidePanelController()

    private let guideModel = PermissionGuideModel()

    private var panel: NSPanel?
    private var permissionName = "屏幕录制"
    private var settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private init() {}

    /// 显示悬浮授权窗（已显示则前置）。
    /// 定位竞态：调用方通常刚 NSWorkspace.open 系统设置——冷启动时其
    /// 窗口要 1-2s 才出现，立刻定位必然落空（落到屏幕底部，用户感知
    /// 为「没附着设置」）。轮询重定位直到找到设置窗口或超时。
    func show(permissionName: String, settingsURL: URL) {
        self.permissionName = permissionName
        self.settingsURL = settingsURL

        if panel == nil {
            createPanel()
        }
        guideModel.attached = false
        positionBelowSettings()
        guard let panel else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        fadeIn(panel)
        repositionUntilAttached()
    }

    /// 轮询重定位：最多 10 次 × 0.6s，找到系统设置窗口即附着并停止。
    private func repositionUntilAttached() {
        Task { @MainActor in
            for attempt in 0..<10 {
                if panel == nil { return }   // 已被关闭
                if findSystemSettingsWindowFrame() != nil {
                    positionBelowSettings()
                    self.guideModel.attached = true
                    let diag = "[PermissionGuide] attached attempt=\(attempt) "
                        + "panel=\(panel?.frame ?? .zero) "
                        + "settings=\(findSystemSettingsWindowFrame().map { NSStringFromRect($0) } ?? "?")"
                    // 走项目统一日志（AppLogger 已把 stdout 重定向到
                    // ~/Library/Logs/WhisperASR/app.log）：此前另写一份
                    // /tmp/permission_guide_log.txt，日志分散且 /tmp 会被系统清理。
                    AppLogger.shared.log(.ui, diag)
                    return
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        if MotionPrefs.shared.reduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// 出场：expo-out（cubic-bezier(.16, 1, .3, 1)），与主窗口面板同一曲线。
    private func fadeIn(_ panel: NSPanel) {
        if MotionPrefs.shared.reduceMotion {
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 录制入口统一授权闸：已授权返回 true；未授权则一键直达授权
    ///（触发系统弹窗 + 悬浮授权窗附着到系统设置 + 打开录屏面板），
    /// 返回 false。所有录制入口（工具栏/主界面卡/菜单栏/浮层选应用）
    /// 在启动流程前调用。
    @discardableResult
    func authorizeForRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()   // 系统弹窗（仅首次；之后静默）
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
        show(permissionName: "屏幕录制", settingsURL: url)
        return false
    }

    /// 跨进程查找系统设置主窗口的 frame（CGWindowList，
    /// Cocoa 坐标系与 NSWindow.frame 可直接互换）。
    private func findSystemSettingsWindowFrame() -> NSRect? {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        for info in list {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard owner == "系统设置" || owner == "System Settings" else { continue }
            // 注意：kCGWindowName 在自身无屏幕录制权限时对其他进程窗口
            // 一律为空——【不能用标题过滤】（未授权恰恰是本流程的前提）。
            // 用窗口层级（layer 0 = 普通窗口）+ 最小宽度过滤辅助小窗。
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat,
                  w > 500 else { continue }
            // CG 坐标（左上原点）→ Cocoa 坐标（左下原点）。
            guard let screenHeight = NSScreen.screens.first?.frame.height else { return nil }
            return NSRect(x: x, y: screenHeight - y - h, width: w, height: h)
        }
        return nil
    }

    // MARK: - 面板

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 钉在系统设置下方：禁用一切用户拖动（含标题条），位置只由
        // positionBelowSettings() 通过 setFrame 决定。
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        // 注意：这里【不】转发背景 mouseDown 到 performDrag。本面板的定位
        // 语义是「钉在系统设置窗口下方」，让用户拖走会脱离锚点、也拖不回
        // 列表；面板位置只由 positionBelowSettings() 决定。
        let host = NSHostingView(rootView: PermissionGuideFloatingContent(
            model: guideModel,
            onClose: { [weak self] in self?.dismiss() }
        ))
        panel.contentView = host
        self.panel = panel
    }

    /// 定位：系统设置窗口下方居中。系统设置是【另一个进程】——它的
    /// 窗口不在 NSApp.windows 里（此前用 NSApp.windows 找永远落空，
    /// 兜底到屏幕底部，用户感知为「没附着到设置上」）。跨进程用
    /// CGWindowList 按窗口属主名定位。
    private func positionBelowSettings() {
        guard let panel else { return }
        var target = panel.frame
        if let settingsFrame = findSystemSettingsWindowFrame() {
            target = NSRect(
                x: settingsFrame.midX - panel.frame.width / 2,
                y: settingsFrame.minY - panel.frame.height - 16,
                width: panel.frame.width,
                height: panel.frame.height)
        } else if let screen = NSScreen.main?.visibleFrame {
            target = NSRect(
                x: screen.midX - panel.frame.width / 2,
                y: screen.minY + 80,
                width: panel.frame.width,
                height: panel.frame.height)
        }
        // 钳制在屏幕内。
        if let visible = NSScreen.main?.visibleFrame {
            target.origin.x = max(visible.minX + 8,
                                  min(target.origin.x, visible.maxX - panel.frame.width - 8))
            target.origin.y = max(visible.minY + 8,
                                  min(target.origin.y, visible.maxY - panel.frame.height - 8))
        }
        panel.setFrame(target, display: true)
    }
}

// MARK: - 悬浮窗内容

/// 悬浮授权窗内容：app 图标（可拖拽）+ 说明 + 关闭。
private struct PermissionGuideFloatingContent: View {
    let model: PermissionGuideModel
    let onClose: () -> Void

    /// 未贴附时的描边脉冲：1.5pt 内描边在 0.25 ↔ 0.7 之间呼吸
    ///（站点的 inset 0 0 0 1.5px 描边手法，用来指「看哪里」而不是加色块）。
    @State private var pulse = false

    private var appURL: URL { Bundle.main.bundleURL }

    var body: some View {
        HStack(spacing: 14) {
            // 可拖拽的 app 图标（AppKit beginDraggingSession：Finder 同款
            // pasteboard file URL，系统设置 TCC 列表接受的标准形态）。
            DraggableAppIcon(fileURL: appURL, iconSide: 48)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: model.attached ? "checkmark.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(model.attached ? Palette.ok : Color.white.opacity(0.75))
                        .background(Circle().fill(Color.black))
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.easeInOut(duration: 0.24), value: model.attached)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("把图标拖进上方的列表")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text("松手即完成授权，完成后点右侧 ✕ 关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                // 贴附状态（等宽微标签）：找到设置窗口前一直是「正在贴附」。
                Text(model.attached ? "已贴附系统设置" : "正在贴附系统设置…")
                    .font(Type.mono(Type.micro))
                    .foregroundStyle(model.attached
                                     ? Palette.ok.opacity(0.9)
                                     : Color.white.opacity(0.45))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.24), value: model.attached)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(14)
        .frame(width: 420)
        .overlay(
            // 锚点脉冲只画在拖拽源（app 图标）上：告诉用户「从这里拖」。
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Color.white.opacity(model.attached ? 0.0 : (pulse ? 0.7 : 0.25)),
                    lineWidth: 1.5
                )
                .padding(6)
                .allowsHitTesting(false)
        )
        .onAppear {
            guard !model.attached, !MotionPrefs.shared.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .background(
            // 纯黑实底（用户要求）：regularMaterial 是实时模糊材质，
            // GPU 开销大；纯色渲染成本接近零。
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    model.attached ? Color.white.opacity(0.22) : Color.white.opacity(0.15),
                    lineWidth: 1
                )
        )
    }
}
