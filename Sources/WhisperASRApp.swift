import SwiftUI

@main
struct WhisperASRApp: App {
    @State private var appState = AppState()
    @State private var audioPlayer = AudioPlayerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(audioPlayer)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 650)

        Settings {
            SettingsView()
        }
    }
}
