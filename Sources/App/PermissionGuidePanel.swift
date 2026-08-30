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
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }

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

    /// 定位：系统设置窗口下方居中（找不到时屏幕下方居中）。
    private func positionBelowSettings() {
        guard let panel else { return }
        // 系统设置窗口：可见、非本浮窗、宽度较大的普通窗口。
        let settingsWindow = NSApp.windows.first {
            $0 != panel && $0.isVisible && $0.frame.width > 600
        }
        var target = panel.frame
        if let settings = settingsWindow {
            let frame = settings.frame
            target = NSRect(
                x: frame.midX - panel.frame.width / 2,
                y: frame.minY - panel.frame.height - 16,
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
    @State private var isPressed = false

    private var appURL: URL { Bundle.main.bundleURL }

    var body: some View {
        HStack(spacing: 14) {
            // 可拖拽的 app 图标（NSItemProvider(contentsOf:)：Finder 同款
            // 文件拖拽注册，系统设置 TCC 列表接受）。
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
                .scaleEffect(isPressed ? 0.95 : 1)
                .onDrag {
                    isPressed = true
                    let provider = NSItemProvider(contentsOf: appURL)
                        ?? NSItemProvider()
                    return provider
                } preview: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.openHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help("按住我，拖到系统设置的列表里")

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
