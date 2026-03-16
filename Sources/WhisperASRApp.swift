import SwiftUI
import AppKit

@main
struct WhisperASRApp: App {
    @State private var appState = AppState()
    @State private var audioPlayer = AudioPlayerManager()
    @State private var audioRecorder = AudioRecorder()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .defaultSize(width: 1000, height: 650)

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

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
