import AppKit
import SwiftUI

// MARK: - Debug subtitle tool (self-contained, removable)
//
// Type text and preview it rendered with the same subtitle look as the live
// overlay (v2s-style transparency, fade-in, Apple corner radius) — no screen
// recording or live transcription needed.
//
// This feature is intentionally isolated:
//   * It does not touch AppState, the recording pipeline, or the floating overlay.
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

/// 字幕预览样式：原模糊入场 vs 逐字动画（SplitText 效果）。
private enum SubtitlePreviewMode: String, CaseIterable, Identifiable {
    case blur = "原样式（模糊入场）"
    case split = "逐字动画（SplitText）"

    var id: String { rawValue }
}

private final class DebugSubtitleModel: ObservableObject {
    @Published var text = ""
    @Published var translation = ""
    @Published var previewMode: SubtitlePreviewMode = .split
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

    func show(text: String, translation: String) {
        model.text = text
        model.translation = translation
        if panel == nil {
            createPanel()
        }
        panel?.orderFrontRegardless()
    }

    func update(text: String, translation: String) {
        model.text = text
        model.translation = translation
    }

    func setPreviewMode(_ mode: SubtitlePreviewMode) {
        model.previewMode = mode
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
            if !model.translation.isEmpty {
                previewSubtitle(text: model.translation, fontSize: 19, opacity: 1.0)
                .frame(maxWidth: .infinity)
            }
            if !model.text.isEmpty {
                previewSubtitle(text: model.text, fontSize: 26, opacity: 0.82)
                .frame(maxWidth: .infinity)
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

    /// 按预览模式渲染：逐字动画（SplitText）或原模糊入场样式。
    @ViewBuilder
    private func previewSubtitle(text: String, fontSize: CGFloat, opacity: Double) -> some View {
        if model.previewMode == .split {
            SplitSubtitleText(
                text: text,
                fontSize: fontSize,
                fontWeight: .semibold,
                foregroundStyle: .white.opacity(opacity),
                staggerDelay: 0.06,
                duration: 0.5,
                fromOffsetY: 28,
                fromScale: 0.92
            )
        } else {
            SubtitleBlurText(
                text: text,
                fontSize: fontSize,
                fontWeight: .semibold,
                foregroundStyle: .white.opacity(opacity)
            )
        }
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
    @State private var translation = ""
    @State private var showFloating = false
    @State private var previewMode = SubtitlePreviewMode.split

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("字幕浮层调试")
                .font(.headline)

            TextField("输入字幕文本…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, _ in
                    updateFloating()
                }

            TextField("翻译文本（可选）…", text: $translation)
                .textFieldStyle(.roundedBorder)
                .onChange(of: translation) { _, _ in
                    updateFloating()
                }

            Toggle("以浮层显示（置顶，可拖动）", isOn: $showFloating)
                .onChange(of: showFloating) { _, isOn in
                    if isOn {
                        DebugSubtitleFloatingPanel.shared.setPreviewMode(previewMode)
                        DebugSubtitleFloatingPanel.shared.show(text: text, translation: translation)
                    } else {
                        DebugSubtitleFloatingPanel.shared.hide()
                    }
                }

            Picker("预览样式", selection: $previewMode) {
                ForEach(SubtitlePreviewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: previewMode) { _, mode in
                DebugSubtitleFloatingPanel.shared.setPreviewMode(mode)
            }

            Divider()

            subtitlePreview(text: text, translation: translation)
                .frame(maxWidth: .infinity, minHeight: 140)
        }
        .padding(20)
        .frame(width: 540, height: 400)
    }

    private func updateFloating() {
        if showFloating {
            DebugSubtitleFloatingPanel.shared.update(text: text, translation: translation)
        }
    }

    private func subtitlePreview(text: String, translation: String) -> some View {
        VStack(alignment: .center, spacing: 8) {
            if !translation.isEmpty {
                previewSubtitle(text: translation, fontSize: 19, opacity: 1.0)
                .frame(maxWidth: .infinity)
            }
            if !text.isEmpty {
                previewSubtitle(text: text, fontSize: 26, opacity: 0.82)
                .frame(maxWidth: .infinity)
            } else if translation.isEmpty {
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

    /// 按预览模式渲染：逐字动画（SplitText）或原模糊入场样式。
    @ViewBuilder
    private func previewSubtitle(text: String, fontSize: CGFloat, opacity: Double) -> some View {
        if previewMode == .split {
            SplitSubtitleText(
                text: text,
                fontSize: fontSize,
                fontWeight: .semibold,
                foregroundStyle: .white.opacity(opacity),
                staggerDelay: 0.06,
                duration: 0.5,
                fromOffsetY: 28,
                fromScale: 0.92
            )
        } else {
            SubtitleBlurText(
                text: text,
                fontSize: fontSize,
                fontWeight: .semibold,
                foregroundStyle: .white.opacity(opacity)
            )
        }
    }
}
