import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioPlayerManager.self) var audioPlayer
    @State private var showModelDownload = false

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
        .sheet(isPresented: $showModelDownload) {
            ModelDownloadView(isPresented: $showModelDownload)
        }
        .onAppear {
            if !TranscriptionService.modelExists() {
                showModelDownload = true
            }
        }
    }
}
