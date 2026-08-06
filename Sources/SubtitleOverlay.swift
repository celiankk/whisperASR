import AppKit
import SwiftUI

// MARK: - Persisted keys

enum SubtitleOverlayKeys {
    static let visible = "subtitleOverlayVisible"
    static let sourceFontSize = "subtitleOverlaySourceFontSize"
    static let translationFontSize = "subtitleOverlayTranslationFontSize"
    static let borderOpacity = "subtitleOverlayBorderOpacity"
    static let frame = "subtitleOverlayFrame"
}

// MARK: - Apple-spec metrics

enum SubtitleOverlayMetrics {
    /// Apple's standard macOS window corner radius: 10pt on macOS 11–15,
    /// 26pt on macOS 26+ (Tahoe's larger window corners). v2s used a
    /// hardcoded 16pt; we follow the system's own windows instead.
    static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            return 26
        }
        return 10
    }
}

// MARK: - Panel

/// Borderless, non-activating panel so subtitles float above other apps
/// without stealing focus (same approach as v2s's overlay).
private final class SubtitleOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI content

struct SubtitleOverlayView: View {
    let appState: AppState
    var onClose: () -> Void = {}

    /// v2s's caption-flow spring, used for subtitle fade-in.
    static let captionFlowAnimation = Animation.interactiveSpring(
        response: 0.32,
        dampingFraction: 0.88,
        blendDuration: 0.08
    )

    private var sourceFontSize: CGFloat { appState.subtitleOverlaySourceFontSize }
    private var translationFontSize: CGFloat { appState.subtitleOverlayTranslationFontSize }
    private var borderOpacity: Double { appState.subtitleOverlayBorderOpacity }

    private var segments: [TranscriptionSegment] { appState.liveSegments }

    private var currentSegment: TranscriptionSegment? { segments.last }

    private var currentTranslation: String? {
        guard appState.enableLiveTranslation else { return nil }
        let index = segments.count - 1
        guard index >= 0, index < appState.liveTranslatedSegments.count else { return nil }
        let text = appState.liveTranslatedSegments[index]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("关闭字幕浮层")
            }

            if let translation = currentTranslation {
                SubtitleBlurText(
                    text: translation,
                    fontSize: translationFontSize,
                    fontWeight: .semibold,
                    foregroundStyle: .white.opacity(1.0)
                )
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }

            if let segment = currentSegment {
                SubtitleBlurText(
                    text: segment.text,
                    fontSize: sourceFontSize,
                    fontWeight: .semibold,
                    foregroundStyle: .white.opacity(0.82)
                )
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else {
                // Welcome placeholder: the top subtitle bar is ready.
                SubtitleBlurText(
                    text: "欢迎使用，顶部字幕条已经准备好了。",
                    fontSize: sourceFontSize * 0.8,
                    fontWeight: .regular,
                    foregroundStyle: .white.opacity(0.75)
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SubtitleOverlayMetrics.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: SubtitleOverlayMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 1)
                )
        )
        .animation(Self.captionFlowAnimation, value: currentSegment == nil)
        .animation(Self.captionFlowAnimation, value: currentTranslation == nil)
    }
}

// MARK: - Controller

@MainActor
final class SubtitleOverlayController: NSObject {
    private let panel = SubtitleOverlayPanel(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 180),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var hostingView: NSHostingView<SubtitleOverlayView>?
    private weak var appState: AppState?
    private var observationTask: Task<Void, Never>?
    private var lastAppliedHeight: CGFloat = 0

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.animationBehavior = .utilityWindow
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameChanged),
            name: NSWindow.didMoveNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameChanged),
            name: NSWindow.didResizeNotification,
            object: panel
        )
    }

    var isVisible: Bool { panel.isVisible }

    func show(appState: AppState) {
        self.appState = appState

        let root = SubtitleOverlayView(appState: appState) { [weak self] in
            self?.closeFromButton()
        }

        if let hostingView {
            hostingView.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            hostingView = hosting
        }

        if let saved = savedFrame, saved.width > 40, saved.height > 40 {
            panel.setFrame(saved, display: true)
        } else {
            placeAtDefaultPosition()
        }

        panel.orderFrontRegardless()
        lastAppliedHeight = 0
        observeAppState()
        resizePanelToFit()
    }

    func hide() {
        observationTask?.cancel()
        observationTask = nil
        panel.orderOut(nil)
    }

    func resetPosition() {
        placeAtDefaultPosition()
    }

    // MARK: - Frame handling

    private func placeAtDefaultPosition() {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = NSSize(width: 640, height: 180)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 60
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private var savedFrame: NSRect? {
        guard let string = UserDefaults.standard.string(forKey: SubtitleOverlayKeys.frame) else {
            return nil
        }
        return NSRectFromString(string)
    }

    @objc private func frameChanged() {
        guard panel.isVisible else { return }
        UserDefaults.standard.set(
            NSStringFromRect(panel.frame),
            forKey: SubtitleOverlayKeys.frame
        )
    }

    private func resizePanelToFit() {
        guard let hostingView else { return }
        let fitting = hostingView.fittingSize
        guard fitting.height > 0 else { return }

        var frame = panel.frame
        // Anchor the top edge: this is a top subtitle bar, so height changes
        // must grow/shrink downward instead of pushing the panel upward.
        let oldTop = frame.maxY
        let targetHeight = min(max(fitting.height + 4, 90), 420)
        guard abs(targetHeight - frame.height) > 2 else { return }

        frame.size.height = targetHeight
        frame.origin.y = oldTop - targetHeight

        // Keep the whole bar inside the visible screen.
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxY > visible.maxY {
                frame.origin.y = visible.maxY - frame.height
            }
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY
            }
        }

        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Observation

    private func observeAppState() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self, let appState else { return }
            withObservationTracking {
                _ = appState.liveSegments
                _ = appState.liveTranslatedSegments
                _ = appState.enableLiveTranslation
                _ = appState.subtitleOverlaySourceFontSize
                _ = appState.subtitleOverlayTranslationFontSize
                _ = appState.subtitleOverlayBorderOpacity
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.resizePanelToFit()
                    self?.observeAppState()
                }
            }
        }
    }

    private func closeFromButton() {
        appState?.setSubtitleOverlayVisible(false)
    }
}
