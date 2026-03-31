import SwiftUI
import ScreenCaptureKit

struct RecordingView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @State private var shouldAutoScroll = true
    @State private var isAlwaysOnTop = false
    @State private var translationOnly = false
    @AppStorage("transcriptFontSize") private var transcriptFontSizeRaw = TranscriptFontSize.normal.rawValue
    private var fontSize: TranscriptFontSize { TranscriptFontSize(rawValue: transcriptFontSizeRaw) ?? .normal }

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

                if appState.enableLiveTranslation {
                    Button {
                        translationOnly.toggle()
                    } label: {
                        Image(systemName: translationOnly ? "eye.fill" : "eye")
                            .foregroundStyle(translationOnly ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(translationOnly ? "Show original and translation" : "Show translation only")
                }

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
            if recorder.pinWindow {
                recorder.pinWindow = false
                isAlwaysOnTop = true
                setWindowAlwaysOnTop(true)
            }
        }
    }

    // MARK: - Live Transcript

    private var liveTranscriptView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.isLiveTranscribing && appState.liveSegments.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for audio...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .frame(maxHeight: .infinity)
            }

            if !appState.liveSegments.isEmpty {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(appState.liveSegments.enumerated()), id: \.offset) { index, segment in
                            LiveSegmentRow(
                                segment: segment,
                                translation: index < appState.liveTranslatedSegments.count
                                    ? appState.liveTranslatedSegments[index] : "",
                                fontSize: fontSize,
                                translationOnly: translationOnly
                            )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .listRowBackground(Color.clear)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("bottomAnchor")
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 1)
                    .background(
                        ScrollPositionObserver(isAtBottom: $shouldAutoScroll)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                    )
                    .onChange(of: appState.liveSegments.count) { _, _ in
                        deferredScrollToBottom(proxy: proxy)
                    }
                    .onChange(of: appState.liveTranslatedSegments) { _, _ in
                        deferredScrollToBottom(proxy: proxy)
                    }
                    .overlay { WindowDragOverlay() }
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

    /// Capture scroll intent before layout changes can race with the observer,
    /// then defer the actual scroll until LazyVStack finishes layout.
    private func deferredScrollToBottom(proxy: ScrollViewProxy) {
        let wasAtBottom = shouldAutoScroll
        guard wasAtBottom, !appState.liveSegments.isEmpty else { return }
        DispatchQueue.main.async {
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
        }
    }

    private func stopAndDismiss() {
        let capturedSegments = appState.liveSegments
        let capturedText = capturedSegments.map { $0.text }.joined()
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
            await MainActor.run { recorder.state = .idle }
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

}

// MARK: - Live Segment Row

/// Extracted row view with Equatable conformance so SwiftUI can skip
/// re-rendering rows whose segment + translation haven't changed.
private struct LiveSegmentRow: View, Equatable {
    let segment: TranscriptionSegment
    let translation: String
    let fontSize: TranscriptFontSize
    let translationOnly: Bool

    private static let translationColor = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemTeal.withAlphaComponent(0.85)
            : NSColor.systemBlue.withAlphaComponent(0.75)
    }))

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !translationOnly {
                Text(segment.text.trimmingCharacters(in: .whitespaces))
                    .font(fontSize.bodyFont)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !translation.isEmpty {
                Text(translation)
                    .font(translationOnly ? fontSize.bodyFont : fontSize.translationFont)
                    .foregroundStyle(Self.translationColor)
                    .italic(translationOnly ? false : true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Scroll Position Observer

/// Observes the enclosing NSScrollView's scroll position via native bounds-change
/// notifications. Uses a 150px threshold to tolerate content growth (e.g. translations
/// appended) without prematurely disabling auto-scroll.
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
            guard !isSetUp else { return }
            // Try enclosingScrollView first (works when inside the scroll view).
            // Fall back to searching the view hierarchy (needed when placed as
            // .background on a List, where the observer is a sibling of the NSScrollView).
            guard let scrollView = view.enclosingScrollView ?? Self.findScrollView(from: view) else { return }
            isSetUp = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewDidScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        /// Walk up the view hierarchy and search sibling subtrees for an NSScrollView
        /// whose document view is an NSTableView (i.e., the List's backing scroll view).
        private static func findScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view.superview
            while let parent = current {
                if let found = findTableScrollView(in: parent) { return found }
                current = parent.superview
            }
            return nil
        }

        private static func findTableScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView, sv.documentView is NSTableView { return sv }
            for subview in view.subviews {
                if let found = findTableScrollView(in: subview) { return found }
            }
            return nil
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
                self.isAtBottom = distanceFromBottom <= 150
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

// MARK: - Window Drag Overlay

/// Transparent overlay that lets single-finger click+drag move the window
/// while forwarding two-finger trackpad scroll events to the List beneath.
private struct WindowDragOverlay: NSViewRepresentable {
    class DragView: NSView {
        weak var targetScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.targetScrollView = self?.findScrollView()
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            if targetScrollView == nil { targetScrollView = findScrollView() }
            targetScrollView?.scrollWheel(with: event)
        }

        private func findScrollView() -> NSScrollView? {
            var current: NSView? = superview
            while let parent = current {
                if let sv = Self.findTableScrollView(in: parent) { return sv }
                current = parent.superview
            }
            return nil
        }

        private static func findTableScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView, sv.documentView is NSTableView { return sv }
            for sub in view.subviews {
                if let found = findTableScrollView(in: sub) { return found }
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
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
