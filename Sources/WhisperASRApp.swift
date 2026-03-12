import SwiftUI
import AppKit

@main
struct WhisperASRApp: App {
    @State private var appState = AppState()
    @State private var audioPlayer = AudioPlayerManager()
    @State private var audioRecorder = AudioRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1000, height: 650)

        Settings {
            SettingsView()
        }
    }
}
