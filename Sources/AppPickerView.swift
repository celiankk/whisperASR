import SwiftUI
import ScreenCaptureKit

struct AppPickerView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) var openWindow
    @State private var searchText = ""
    @AppStorage("liveTranslationPref") private var liveTranslationPref = false

    var body: some View {
        @Bindable var appState = appState
        @Bindable var recorder = recorder
        return VStack(spacing: 0) {
            switch recorder.state {
            case .idle, .loading:
                loadingContent
            case .ready:
                pickerContent
            case .permissionDenied:
                permissionDeniedContent
            default:
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(
            minWidth: 360, idealWidth: 420, maxWidth: .infinity,
            minHeight: 400, idealHeight: 400, maxHeight: .infinity
        )
        .background(WindowCenterer())
        .onChange(of: appState.enableLiveTranscription) { _, newValue in
            if !newValue { appState.enableLiveTranslation = false }
        }
        .onAppear {
            if recorder.state == .idle {
                recorder.loadAvailableApps()
            }
            appState.enableLiveTranslation = liveTranslationPref
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

    // MARK: - Picker

    private var pickerContent: some View {
        @Bindable var appState = appState
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

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            List(filteredApps, id: \.bundleIdentifier, selection: Binding(
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
                Toggle(isOn: $appState.enableLiveTranscription) {
                    Label("Live", systemImage: "text.word.spacing")
                }
                Toggle(isOn: Binding(
                    get: { appState.enableLiveTranslation },
                    set: { appState.enableLiveTranslation = $0; liveTranslationPref = $0 }
                )) {
                    Image(systemName: "character.bubble")
                }
                .disabled(!appState.enableLiveTranscription)
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
                        openWindow(id: "recording")
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.selectedApp == nil)
            }
            .padding(12)
        }
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

    private var filteredApps: [SCRunningApplication] {
        guard !searchText.isEmpty else { return sortedApps }
        return sortedApps.filter {
            $0.applicationName.localizedCaseInsensitiveContains(searchText)
        }
    }

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
}

// MARK: - Window Centerer

/// Centers this window on the main WhisperASR window when it first appears.
private struct WindowCenterer: NSViewRepresentable {
    class CenterView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            guard let mainWindow = NSApplication.shared.windows.first(where: {
                $0 !== window && $0.isVisible && $0.title != "Recording"
            }) else { return }
            let mf = mainWindow.frame
            let wf = window.frame
            window.setFrameOrigin(NSPoint(x: mf.midX - wf.width / 2, y: mf.midY - wf.height / 2))
        }
    }

    func makeNSView(context: Context) -> NSView { CenterView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
