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

@MainActor
final class PermissionGuidePanelController {
    static let shared = PermissionGuidePanelController()

    private var panel: NSPanel?
    private var permissionName = "屏幕录制"
    private var settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private init() {}

    /// 显示悬浮授权窗（已显示则前置）。
    func show(permissionName: String, settingsURL: URL) {
        self.permissionName = permissionName
        self.settingsURL = settingsURL

        if panel == nil {
            createPanel()
        }
        positionBelowSettings()
        panel?.orderFrontRegardless()
        let settingsFrame = findSystemSettingsWindowFrame()
        let diag = "[PermissionGuide] shown frame=\(panel?.frame ?? .zero) "
            + "settings=\(settingsFrame.map { NSStringFromRect($0) } ?? "not-found") "
            + "visible=\(panel?.isVisible ?? false)"
        print(diag)
        try? diag.write(to: URL(fileURLWithPath: "/tmp/permission_guide_log.txt"),
                        atomically: true, encoding: .utf8)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }

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
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: PermissionGuideFloatingContent(
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
    let onClose: () -> Void

    private var appURL: URL { Bundle.main.bundleURL }

    var body: some View {
        HStack(spacing: 14) {
            // 可拖拽的 app 图标（AppKit beginDraggingSession：Finder 同款
            // pasteboard file URL，系统设置 TCC 列表接受的标准形态）。
            DraggableAppIcon(fileURL: appURL, iconSide: 48)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))

            VStack(alignment: .leading, spacing: 3) {
                Text("把图标拖进上方的列表")
                    .font(.system(size: 13, weight: .medium))
                Text("松手即完成授权，完成后点右侧 ✕ 关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}
