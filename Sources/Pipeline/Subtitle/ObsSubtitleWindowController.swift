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
        if isVisible {
            dismiss()
        } else {
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
        panel.contentView = NSHostingView(rootView: ObsSubtitleView(viewModel: viewModel))
        panel.orderFrontRegardless()
        self.panel = panel
        AppLogger.shared.log(.window, "OBS subtitle window presented")
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
        AppLogger.shared.log(.window, "OBS subtitle window dismissed")
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
                .lineLimit(3)
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
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 0)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 0)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: -1, y: 0)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)   // 纯显示：指针事件全部穿过（拖动靠窗口层）
    }
}
