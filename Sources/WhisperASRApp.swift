import SwiftUI
import AppKit

@main
struct WhisperASRApp: App {
    @State private var appState = AppState()
    @State private var audioPlayer = AudioPlayerManager()
    @State private var audioRecorder = AudioRecorder()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("WhisperASR", id: "main") {
            ContentView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.audioRecorder = audioRecorder
                    appDelegate.openWindow = openWindow
                    appDelegate.processPendingURL()
                    // Recover live transcription from a previous crash/hang
                    if appState.hasLiveRecoveryData {
                        appState.importRecoveredTranscription()
                    }
                }
                .onOpenURL { url in
                    appDelegate.handleURL(url)
                }
        }
        .defaultSize(width: 1000, height: 650)

        Window("Select App to Record", id: "app-picker") {
            AppPickerView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
        }
        .defaultSize(width: 420, height: 400)
        .windowResizability(.contentSize)

        Window("Recording", id: "recording") {
            RecordingView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
        }
        .defaultSize(width: 420, height: 250)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var audioRecorder: AudioRecorder?
    var openWindow: OpenWindowAction?
    var launchedViaURL = false
    private var pendingURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let icon = AppIconGenerator.generate()
        NSApplication.shared.applicationIconImage = icon
        let imageView = NSImageView(image: icon)
        NSApplication.shared.dockTile.contentView = imageView
        NSApplication.shared.dockTile.display()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "whisperasr" else { return }
        launchedViaURL = true
        // If openWindow is ready, handle immediately; otherwise queue it
        if openWindow != nil {
            handleURL(url)
        } else {
            pendingURL = url
        }
    }

    func handleURL(_ url: URL) {
        guard url.scheme == "whisperasr", url.host == "record",
              let openWindow else { return }

        // Parse optional recording name from query: whisperasr://record?name=MyMeeting
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let nameItem = components.queryItems?.first(where: { $0.name == "name" }),
           let name = nameItem.value, !name.isEmpty {
            audioRecorder?.customRecordingName = name
        }

        let isRecording = audioRecorder?.state == .recording
        let targetWindowID = isRecording ? "recording" : "app-picker"
        let targetTitle = isRecording ? "Recording" : "Select App to Record"

        openWindow(id: targetWindowID)

        // Wait for SwiftUI to finish creating the window, then reorder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Hide the main window if this was a cold launch via URL
            if self.launchedViaURL {
                for window in NSApplication.shared.windows where window.title == "WhisperASR" {
                    window.orderOut(nil)
                }
            }
            // Bring target window to front
            for window in NSApplication.shared.windows where window.title == targetTitle {
                window.makeKeyAndOrderFront(nil)
                break
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func processPendingURL() {
        if let url = pendingURL {
            pendingURL = nil
            handleURL(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
    }
}
