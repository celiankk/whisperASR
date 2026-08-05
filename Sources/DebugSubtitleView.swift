import AppKit
import SwiftUI

// MARK: - Debug subtitle tool (self-contained, removable)
//
// Type text and preview it rendered with the same subtitle look as the live
// overlay (v2s-style transparency, fade-in, Apple corner radius) — no screen
// recording or live transcription needed.
//
// This feature is intentionally isolated:
//   * It does not touch AppState, the recording pipeline, or SubtitleOverlay.
//   * To remove it: delete this file and the "debug-subtitle" Window scene +
//     "调试" CommandMenu in WhisperASRApp.swift.

private enum DebugSubtitleMetrics {
    /// Apple's standard macOS window corner radius: 10pt on macOS 11–15,
    /// 26pt on macOS 26+ (Tahoe). Mirrors the live overlay.
    static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            return 26
        }
        return 10
    }
}

private final class DebugSubtitleModel: ObservableObject {
    @Published var text = ""
}

/// Borderless, non-activating floating panel that mirrors the typed text
/// exactly like the real overlay (no focus stealing, floats above apps).
@MainActor
private final class DebugSubtitleFloatingPanel: NSObject {
    static let shared = DebugSubtitleFloatingPanel()

    private let model = DebugSubtitleModel()
    private var panel: NSPanel?

    private override init() {
        super.init()
    }

    func show(text: String) {
        model.text = text
        if panel == nil {
            createPanel()
        }
        panel?.orderFrontRegardless()
    }

    func update(text: String) {
        model.text = text
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .statusBar
        newPanel.isMovableByWindowBackground = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        let hosting = NSHostingView(rootView: DebugFloatingSubtitleView(model: model))
        hosting.autoresizingMask = [.width, .height]
        newPanel.contentView = hosting

        let screen = newPanel.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let size = newPanel.frame.size
            newPanel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.minY + 80
            ))
        }
        panel = newPanel
    }
}

/// The floating panel's subtitle rendering (same style as the live overlay).
private struct DebugFloatingSubtitleView: View {
    @ObservedObject var model: DebugSubtitleModel

    var body: some View {
        VStack(spacing: 8) {
            if !model.text.isEmpty {
                SubtitleBlurText(
                    text: model.text,
                    fontSize: 26,
                    fontWeight: .semibold,
                    foregroundStyle: .white.opacity(0.82)
                )
                    .id(model.text)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else {
                Text("…")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DebugSubtitleMetrics.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: DebugSubtitleMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .animation(DebugSubtitleView.captionFlowAnimation, value: model.text)
        .frame(width: 640)
    }
}

/// Debug window: text field + styled preview + toggle for the floating panel.
struct DebugSubtitleView: View {
    /// v2s's caption-flow spring, used for subtitle fade-in (mirrors overlay).
    static let captionFlowAnimation = Animation.interactiveSpring(
        response: 0.32,
        dampingFraction: 0.88,
        blendDuration: 0.08
    )

    @State private var text = ""
    @State private var showFloating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("字幕浮层调试")
                .font(.headline)

            TextField("输入字幕文本…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, newValue in
                    updateFloating(newValue)
                }

            Toggle("以浮层显示（置顶，可拖动）", isOn: $showFloating)
                .onChange(of: showFloating) { _, isOn in
                    if isOn {
                        DebugSubtitleFloatingPanel.shared.show(text: text)
                    } else {
                        DebugSubtitleFloatingPanel.shared.hide()
                    }
                }

            Divider()

            subtitlePreview(text: text)
                .frame(maxWidth: .infinity, minHeight: 140)
        }
        .padding(20)
        .frame(width: 540, height: 400)
    }

    private func updateFloating(_ newText: String) {
        if showFloating {
            DebugSubtitleFloatingPanel.shared.update(text: newText)
        }
    }

    private func subtitlePreview(text: String) -> some View {
        VStack(alignment: .center, spacing: 8) {
            if !text.isEmpty {
                SubtitleBlurText(
                    text: text,
                    fontSize: 26,
                    fontWeight: .semibold,
                    foregroundStyle: .white.opacity(0.82)
                )
                    .id(text)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else {
                Text("在此输入文字，上方预览字幕样式")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DebugSubtitleMetrics.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: DebugSubtitleMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .animation(Self.captionFlowAnimation, value: text)
    }
}
