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
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.openWindow = openWindow
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
    var openWindow: OpenWindowAction?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let icon = AppIconGenerator.generate()
        NSApplication.shared.applicationIconImage = icon
        // Force the Dock tile to use our icon (needed for bare executables from swift run)
        let imageView = NSImageView(image: icon)
        NSApplication.shared.dockTile.contentView = imageView
        NSApplication.shared.dockTile.display()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
    }
}
