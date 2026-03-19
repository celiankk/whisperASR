import SwiftUI
import ScreenCaptureKit

struct RecordingView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @State private var enableLiveTranscription = true
    @State private var shouldAutoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            switch recorder.state {
            case .idle, .loading:
                loadingContent
            case .ready:
                appPickerContent
            case .recording:
                recordingContent
            case .saving:
                savingContent
            case .permissionDenied:
                permissionDeniedContent
            }
        }
        .frame(
            minWidth: 360, idealWidth: 420, maxWidth: .infinity,
            minHeight: (recorder.state == .recording && !enableLiveTranscription) ? 180 : 400,
            idealHeight: (recorder.state == .recording && !enableLiveTranscription) ? 200 : 500,
            maxHeight: .infinity
        )
        .onChange(of: enableLiveTranscription) { _, newValue in
            if !newValue { appState.enableLiveTranslation = false }
        }
        .onAppear {
            if recorder.state == .idle {
                recorder.loadAvailableApps()
            }
        }
    }

    // MARK: - Loading

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading applications...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - App Picker

    private var appPickerContent: some View {
        @Bindable var recorder = recorder
        return VStack(spacing: 0) {
            Text("Select App to Record")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if let error = recorder.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            List(sortedApps, id: \.bundleIdentifier, selection: Binding(
                get: { recorder.selectedApp?.bundleIdentifier },
                set: { id in
                    recorder.selectedApp = recorder.availableApps.first { $0.bundleIdentifier == id }
                }
            )) { app in
                HStack(spacing: 10) {
                    appIcon(for: app)
                        .frame(width: 24, height: 24)
                    Text(app.applicationName)
                        .lineLimit(1)
                }
                .tag(app.bundleIdentifier)
            }

            Divider()

            HStack(spacing: 12) {
                Toggle(isOn: $recorder.includeMicrophone) {
                    Image(systemName: "mic")
                }
                Toggle(isOn: $enableLiveTranscription) {
                    Label("Live", systemImage: "text.word.spacing")
                }
                Toggle(isOn: Binding(
                    get: { appState.enableLiveTranslation },
                    set: { appState.enableLiveTranslation = $0 }
                )) {
                    Image(systemName: "character.bubble")
                }
                .disabled(!enableLiveTranscription)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack {
                Button("Cancel") {
                    recorder.state = .idle
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Start Recording") {
                    if let app = recorder.selectedApp {
                        recorder.startRecording(app: app)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.selectedApp == nil)
            }
            .padding(12)
        }
    }

    // MARK: - Recording

    private var recordingContent: some View {
        @Bindable var recorder = recorder
        return VStack(spacing: 12) {
            // Header: indicator + duration + minimize button
            ZStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .shadow(color: .red.opacity(0.6), radius: 6)
                        .modifier(PulsingModifier())

                    Text(formatDuration(recorder.recordingDuration))
                        .font(.system(size: 24, weight: .light, design: .monospaced))
                }

                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 12)

            Divider()
                .padding(.horizontal)

            // Live transcription area (only shown if enabled)
            if enableLiveTranscription {
                liveTranscriptView
            } else {
                Spacer()
            }

            Divider()
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Cancel") {
                    appState.stopLiveTranscription()
                    recorder.cancelRecording()
                    dismiss()
                }

                Spacer()

                Button("Stop Recording") {
                    stopAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if enableLiveTranscription, !appState.isLiveTranscribing {
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
                                        // Original transcribed line
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
                                        // Translated line (shown directly below)
                                        if index < appState.liveTranslatedSegments.count,
                                           !appState.liveTranslatedSegments[index].isEmpty {
                                            HStack(alignment: .top, spacing: 6) {
                                                Color.clear
                                                    .frame(width: 44, height: 1)
                                                Text(appState.liveTranslatedSegments[index])
                                                    .font(.caption)
                                                    .foregroundStyle(.blue.opacity(0.75))
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

                            // Bottom anchor for auto-scroll targeting
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

    // MARK: - Permission Denied

    private var permissionDeniedContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Screen Recording Permission Required")
                .font(.headline)

            Text("WhisperASR needs Screen Recording permission to capture audio from other applications.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    recorder.openSystemPreferences()
                }
                .buttonStyle(.borderedProminent)

                Button("Try Again") {
                    recorder.loadAvailableApps()
                }
            }

            Spacer()

            Button("Cancel") {
                recorder.state = .idle
                dismiss()
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var sortedApps: [SCRunningApplication] {
        let recent = recorder.recentAppBundleIDs
        return recorder.availableApps.sorted { a, b in
            let aIdx = recent.firstIndex(of: a.bundleIdentifier)
            let bIdx = recent.firstIndex(of: b.bundleIdentifier)
            switch (aIdx, bIdx) {
            case let (.some(ai), .some(bi)): return ai < bi
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.applicationName < b.applicationName
            }
        }
    }

    private func appIcon(for app: SCRunningApplication) -> some View {
        Group {
            if let nsApp = NSRunningApplication(processIdentifier: app.processID),
               let icon = nsApp.icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
    }

    private func scrollToBottomIfNeeded(proxy: ScrollViewProxy) {
        guard shouldAutoScroll, !appState.liveSegments.isEmpty else { return }
        withAnimation {
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
        }
    }

    private func stopAndDismiss() {
        // Capture live results before clearing
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
        // Fallback: try setup after the current run loop cycle
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
            // Handle both flipped (SwiftUI default) and non-flipped coordinate systems
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
