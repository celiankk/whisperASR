import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioPlayerManager.self) var audioPlayer

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                DetailView()
            }

            if appState.selectedItem?.status == .completed {
                Divider()
                PlayerView()
            }
        }
    }
}
