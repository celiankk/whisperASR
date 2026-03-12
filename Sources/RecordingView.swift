import SwiftUI
import ScreenCaptureKit

struct RecordingView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss

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
        .frame(width: 380, height: 400)
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

            List(recorder.availableApps, id: \.bundleIdentifier, selection: Binding(
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
        VStack(spacing: 20) {
            Spacer()

            // Pulsing red indicator
            Circle()
                .fill(.red)
                .frame(width: 16, height: 16)
                .shadow(color: .red.opacity(0.6), radius: 8)
                .modifier(PulsingModifier())

            Text(formatDuration(recorder.recordingDuration))
                .font(.system(size: 48, weight: .light, design: .monospaced))

            if let app = recorder.selectedApp {
                Text("Recording from \(app.applicationName)")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 16) {
                Button("Cancel") {
                    recorder.cancelRecording()
                    dismiss()
                }

                Button("Stop Recording") {
                    Task {
                        let url = await recorder.stopRecording()
                        if let url {
                            appState.addFile(url: url)
                        }
                        recorder.state = .idle
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.bottom, 20)
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
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
