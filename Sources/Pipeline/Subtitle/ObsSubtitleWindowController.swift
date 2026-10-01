import AppKit
import SwiftUI

// MARK: - OBS 纯净字幕窗（ObsSubtitleWindowController）
//
// 面向录制的第二显示端（对标 LiveTranslate 的 SubtitleWindow）：
// 无边框、全透明、无控制栏、白字描边（不依赖背景可读性），
// 供 OBS/录屏软件窗口采集。与 FloatingLetter 共享同一
// FloatingLetterViewModel（renderer/译文状态同源，双窗同步）。
//
// 开关：菜单栏「OBS 字幕窗」；窗口可拖动（背景拖拽）、置顶。

@MainActor
final class ObsSubtitleWindowController: NSObject {
    static let shared = ObsSubtitleWindowController()

    private var panel: NSPanel?
    private weak var viewModel: FloatingLetterViewModel?

    private override init() { super.init() }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(viewModel: FloatingLetterViewModel) {
        if isVisible, self.viewModel === viewModel {
            dismiss()
        } else {
            // 未显示，或已显示但绑的是上一次录制的 VM（重新录制后重绑，
            // 否则 OBS 窗会永久冻结在旧 VM 的字幕上）。
            if isVisible { dismiss() }
            present(viewModel: viewModel)
        }
    }

    private func present(viewModel: FloatingLetterViewModel) {
        self.viewModel = viewModel
        let panel = NSPanel(
            contentRect: NSRect(x: 400, y: 400, width: 900, height: 180),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = ObsSubtitleHostingView(rootView: ObsSubtitleView(viewModel: viewModel))
        panel.orderFrontRegardless()
        self.panel = panel
        AppLogger.shared.log(.window, "OBS subtitle window presented")
    }

    func dismiss() {
        // 先断开内容视图对 ViewModel 的强引用：controller 侧持的是 weak，
        // 若不置空 contentView，面板连同 hosting 视图会继续持有旧 VM
        //（teardown 后 isTornDown=true，字幕永远不再更新）。
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
        AppLogger.shared.log(.window, "OBS subtitle window dismissed")
    }
}

// MARK: - OBS 窗承载视图（背景拖拽）

/// SwiftUI 层 allowsHitTesting(false)（文字不挡事件），NSView 层转发
/// 背景 mouseDown 到 performDrag —— 原生窗口拖动（Finder 式）。
private final class ObsSubtitleHostingView: NSHostingView<ObsSubtitleView> {
    override func mouseDown(with event: NSEvent) {
        AppLogger.shared.log(.window, "OBS window drag begin")
        window?.performDrag(with: event)
    }
}

/// 纯净字幕视图：白字黑边（描边替代背景，OBS 采集下任何底色可读），
/// 原文大字 + 译文小字，无任何控件/边框。
private struct ObsSubtitleView: View {
    let viewModel: FloatingLetterViewModel

    var body: some View {
        VStack(spacing: 8) {
            // 原文（与 FloatingLetter renderer 同源——逐字动画后的文本）。
            Text(viewModel.subtitleText.isEmpty ? " " : viewModel.subtitleText)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(max(1, viewModel.maxLines))
                .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 0)
                .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 0)
                .shadow(color: .black.opacity(0.9), radius: 2, x: -1, y: 0)
                .padding(.horizontal, 20)
            // 译文（有则显示）。
            if viewModel.showingTranslation,
               let translation = viewModel.translationText, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .lineLimit(max(1, viewModel.maxLines))
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 0)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 0)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: -1, y: 0)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // 注意：不能加 allowsHitTesting(false)——会让 SwiftUI 内容退出
        // hit-test，NSView 层收不到 mouseDown，performDrag 永远不触发
        //（"OBS 浮窗不能拖动"的根因）。文字无交互需求，命中后统一走拖动。

    }
}
