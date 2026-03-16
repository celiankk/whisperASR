import SwiftUI
import ScreenCaptureKit
#if canImport(Translation)
import Translation
#endif

struct RecordingView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @State private var enableLiveTranscription = true

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
        .frame(width: 420, height: (recorder.state == .recording && !enableLiveTranscription) ? 200 : 500)
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

            Toggle(isOn: $recorder.includeMicrophone) {
                Label("Include Microphone", systemImage: "mic")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Toggle(isOn: $enableLiveTranscription) {
                Label("Live Transcription", systemImage: "text.word.spacing")
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

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
            // Header: indicator + duration + app name
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .shadow(color: .red.opacity(0.6), radius: 6)
                    .modifier(PulsingModifier())

                Text(formatDuration(recorder.recordingDuration))
                    .font(.system(size: 24, weight: .light, design: .monospaced))
            }
            .padding(.top, 16)

            if let app = recorder.selectedApp {
                Text("Recording from \(app.applicationName)\(recorder.includeMicrophone ? " + Microphone" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            HStack(spacing: 16) {
                Button("Cancel") {
                    appState.stopLiveTranscription()
                    recorder.cancelRecording()
                    dismiss()
                }

                Button("Stop Recording") {
                    stopAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if enableLiveTranscription {
                appState.startLiveTranscription(recorder: recorder)
            }
        }
        .applyAppleTranslation(appState: appState)
        .alert("Meeting Ended", isPresented: $recorder.meetingEnded) {
            Button("Stop Recording") {
                stopAndDismiss()
            }
            .keyboardShortcut(.defaultAction)
            Button("Continue Recording", role: .cancel) { }
        } message: {
            Text("The Zoom meeting appears to have ended. Would you like to stop recording?")
        }
    }

    // MARK: - Live Transcript

    private var liveTranscriptView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.word.spacing")
                    .foregroundStyle(.orange)
                Text("Live Transcript")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                if appState.isLiveTranscribing && appState.liveText.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for audio...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(.horizontal)

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
                        }
                        .padding(.horizontal)
                    }
                    .onChange(of: appState.liveSegments.count) { _, newCount in
                        if newCount > 0 {
                            withAnimation {
                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
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

    private func stopAndDismiss() {
        appState.stopLiveTranscription()
        Task {
            let url = await recorder.stopRecording()
            if let url {
                appState.addFile(url: url)
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

// MARK: - Apple Translation

#if canImport(Translation)
@available(macOS 15.0, *)
private struct AppleTranslationModifier: ViewModifier {
    let appState: AppState
    @State private var translationConfig: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.translationTrigger) { _, newTrigger in
                // Only activate Apple Translation when OpenAI is NOT configured
                guard newTrigger != nil, !TranslationService.isOpenAIConfigured else { return }
                let targetLang = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
                guard !targetLang.isEmpty else { return }
                if translationConfig != nil {
                    translationConfig?.invalidate()
                } else {
                    let sourceLang = UserDefaults.standard.string(forKey: "sourceLanguage") ?? ""
                    let source: Locale.Language? = sourceLang.isEmpty ? nil : Locale.Language(identifier: sourceLang)
                    translationConfig = .init(source: source, target: Locale.Language(identifier: targetLang))
                }
            }
            .translationTask(translationConfig) { session in
                let texts = appState.pendingTranslationSegments
                guard !texts.isEmpty else { return }
                do {
                    var translations: [String] = []
                    for text in texts {
                        if text.trimmingCharacters(in: .whitespaces).isEmpty {
                            translations.append("")
                        } else {
                            let response = try await session.translate(text)
                            translations.append(response.targetText)
                        }
                    }
                    await MainActor.run {
                        appState.liveTranslatedSegments = translations
                    }
                } catch {
                    print("[Translation] Apple Translation error: \(error)")
                }
            }
    }
}
#endif

extension View {
    @ViewBuilder
    func applyAppleTranslation(appState: AppState) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            self.modifier(AppleTranslationModifier(appState: appState))
        } else {
            self
        }
        #else
        self
        #endif
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
