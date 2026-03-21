import SwiftUI
import ScreenCaptureKit

struct RecordingView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @State private var shouldAutoScroll = true
    @State private var isAlwaysOnTop = false

    var body: some View {
        VStack(spacing: 0) {
            switch recorder.state {
            case .recording:
                recordingContent
            case .saving:
                savingContent
            default:
                Color.clear
            }
        }
        .frame(
            minWidth: 360, idealWidth: 420, maxWidth: .infinity,
            minHeight: appState.enableLiveTranscription ? 200 : 90,
            idealHeight: appState.enableLiveTranscription ? 300 : 200,
            maxHeight: .infinity
        )
        .background(WindowConfigurator())
    }

    // MARK: - Recording

    private var recordingContent: some View {
        @Bindable var recorder = recorder
        return VStack(spacing: 0) {
            // Live transcription area (only shown if enabled)
            if appState.enableLiveTranscription {
                liveTranscriptView
            } else {
                Spacer()
            }

            Divider()

            // Bottom bar: indicator + action buttons + window controls
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.6), radius: 4)
                        .modifier(PulsingModifier())
                    Text(formatDuration(recorder.recordingDuration))
                        .font(.system(size: 13, weight: .light, design: .monospaced))
                }

                Spacer()

                Button("Cancel") {
                    appState.stopLiveTranscription()
                    recorder.cancelRecording()
                    dismiss()
                }

                Button("Finish Recording") {
                    stopAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Divider()
                    .frame(height: 16)

                Button {
                    isAlwaysOnTop.toggle()
                    setWindowAlwaysOnTop(isAlwaysOnTop)
                } label: {
                    Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                        .foregroundStyle(isAlwaysOnTop ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(isAlwaysOnTop ? "Unpin window" : "Keep on top of all windows")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if appState.enableLiveTranscription, !appState.isLiveTranscribing {
                appState.startLiveTranscription(recorder: recorder)
            }
        }
    }

    // MARK: - Live Transcript

    private var liveTranscriptView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.isLiveTranscribing && appState.liveText.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for audio...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
            }

            if !appState.liveSegments.isEmpty || !appState.liveText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if !appState.liveSegments.isEmpty {
                                ForEach(Array(appState.liveSegments.enumerated()), id: \.offset) { index, segment in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(alignment: .top, spacing: 6) {
                                            Text(formatTimestamp(segment.start))
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.orange.opacity(0.7))
                                                .frame(width: 44, alignment: .trailing)

                                            Text(segment.text.trimmingCharacters(in: .whitespaces))
                                                .font(.caption)
                                                .foregroundStyle(.primary.opacity(0.85))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        if index < appState.liveTranslatedSegments.count,
                                           !appState.liveTranslatedSegments[index].isEmpty {
                                            HStack(alignment: .top, spacing: 6) {
                                                Color.clear
                                                    .frame(width: 44, height: 1)
                                                Text(appState.liveTranslatedSegments[index])
                                                    .font(.caption)
                                                    .foregroundStyle(Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                                                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                                                        ? NSColor.systemTeal.withAlphaComponent(0.85)
                                                        : NSColor.systemBlue.withAlphaComponent(0.75)
                                                })))
                                                    .italic()
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                    .id(index)
                                }
                            } else {
                                Text(appState.liveText)
                                    .font(.caption)
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("bottomAnchor")
                        }
                        .padding(.horizontal)
                        .background(
                            ScrollPositionObserver(isAtBottom: $shouldAutoScroll)
                                .frame(width: 0, height: 0)
                                .allowsHitTesting(false)
                        )
                    }
                    .onChange(of: appState.liveSegments.count) { _, _ in
                        scrollToBottomIfNeeded(proxy: proxy)
                    }
                    .onChange(of: appState.liveTranslatedSegments) { _, _ in
                        scrollToBottomIfNeeded(proxy: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Saving

    private var savingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Saving recording...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func scrollToBottomIfNeeded(proxy: ScrollViewProxy) {
        guard shouldAutoScroll, !appState.liveSegments.isEmpty else { return }
        withAnimation {
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
        }
    }

    private func stopAndDismiss() {
        let capturedSegments = appState.liveSegments
        let capturedText = appState.liveText
        let capturedTranslations = appState.liveTranslatedSegments
        let capturedLang: String? = !capturedTranslations.isEmpty
            ? UserDefaults.standard.string(forKey: "targetLanguage") : nil
        let hadLiveResults = appState.isLiveTranscribing && !capturedSegments.isEmpty

        appState.stopLiveTranscription()
        Task {
            let url = await recorder.stopRecording()
            if let url {
                if hadLiveResults {
                    appState.addFileWithLiveResults(
                        url: url, segments: capturedSegments, fullText: capturedText,
                        translatedSegments: capturedTranslations, translationLanguage: capturedLang
                    )
                } else {
                    appState.addFile(url: url)
                }
            }
            recorder.state = .idle
            dismiss()
        }
    }

    private func setWindowAlwaysOnTop(_ alwaysOnTop: Bool) {
        NSApplication.shared.windows
            .first { $0.title == "Recording" }?
            .level = alwaysOnTop ? .floating : .normal
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Scroll Position Observer

/// Observes the enclosing NSScrollView's scroll position via native bounds-change
/// notifications. Updates `isAtBottom` only on actual scroll events (user or
/// programmatic), NOT on content size changes — avoiding race conditions.
private struct ScrollPositionObserver: NSViewRepresentable {
    @Binding var isAtBottom: Bool

    class PassthroughView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onMoveToWindow?()
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        view.onMoveToWindow = {
            context.coordinator.setupIfNeeded(view: view)
        }
        DispatchQueue.main.async {
            context.coordinator.setupIfNeeded(view: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setupIfNeeded(view: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtBottom: $isAtBottom)
    }

    class Coordinator: NSObject {
        @Binding var isAtBottom: Bool
        private var isSetUp = false

        init(isAtBottom: Binding<Bool>) {
            _isAtBottom = isAtBottom
        }

        func setupIfNeeded(view: NSView) {
            guard !isSetUp, let scrollView = view.enclosingScrollView else { return }
            isSetUp = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewDidScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView,
                  let documentView = scrollView.documentView else { return }
            let contentHeight = documentView.frame.height
            let visibleHeight = clipView.bounds.height
            let scrollOffset = clipView.bounds.origin.y
            let distanceFromBottom: CGFloat
            if documentView.isFlipped {
                distanceFromBottom = contentHeight - scrollOffset - visibleHeight
            } else {
                distanceFromBottom = scrollOffset
            }
            DispatchQueue.main.async {
                self.isAtBottom = distanceFromBottom <= 50
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - Window Configurator

/// Hides traffic lights and enables drag-to-move on the Recording window.
private struct WindowConfigurator: NSViewRepresentable {
    class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }

    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Pulsing Animation

private struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
