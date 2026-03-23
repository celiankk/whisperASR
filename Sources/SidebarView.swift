import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @State private var isDropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @State private var renamingItem: TranscriptionItem?
    @State private var renameText = ""
    @State private var searchText = ""

    private let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "mp4", "aac", "flac", "ogg", "wma", "aiff", "caf"
    ]

    private var filteredItems: [TranscriptionItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.items }
        let lowered = query.lowercased()
        return appState.items.filter { item in
            item.fileName.lowercased().contains(lowered) ||
            item.fullText.lowercased().contains(lowered)
        }
    }

    private func matchCount(for item: TranscriptionItem) -> Int {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        let lowered = query.lowercased()
        let text = item.fullText.lowercased()
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: lowered, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    var body: some View {
        @Bindable var appState = appState

        Group {
            if appState.items.isEmpty && searchText.isEmpty {
                emptyDropZone
            } else {
                itemList
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [8, 4]))
                    .foregroundStyle(.blue)
                    .background(.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .toolbar {
            ToolbarItem {
                Button(action: openFilePicker) {
                    Label("Add File", systemImage: "plus")
                }
            }
            ToolbarItem {
                if recorder.state == .recording || recorder.state == .saving {
                    Button {
                        openWindow(id: "recording")
                    } label: {
                        Label("Recording", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        openWindow(id: "app-picker")
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                }
            }
        }
        .onChange(of: recorder.state) { old, new in
            if new == .recording {
                let appState = appState
                let recorder = recorder
                recorder.onMeetingEnded = {
                    handleMeetingEnded(appState: appState, recorder: recorder)
                }
            } else if old == .recording {
                recorder.onMeetingEnded = nil
            }
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingItem = nil }
            Button("Rename") {
                if let item = renamingItem {
                    appState.renameItem(item, to: renameText)
                }
                renamingItem = nil
            }
        } message: {
            Text("Enter a new name for this file.")
        }
    }

    // MARK: - Empty State

    private var emptyDropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drop Audio Files Here")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("MP3, WAV, M4A, MP4, AAC, FLAC")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Item List

    private var itemList: some View {
        @Bindable var state = appState
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            List(selection: $state.selectedItemID) {
                ForEach(filteredItems) { item in
                    HStack(spacing: 8) {
                        statusIcon(item)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileURL.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 4) {
                                Text(statusLabel(item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !searchText.isEmpty {
                                    let count = matchCount(for: item)
                                    if count > 0 {
                                        Text("\(count) match\(count == 1 ? "" : "es")")
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.8))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                    .tag(item.id)
                    .contextMenu {
                        Button("Rename") {
                            renameText = item.fileURL.deletingPathExtension().lastPathComponent
                            renamingItem = item
                        }
                        Button("Copy File") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.writeObjects([item.fileURL as NSURL])
                        }
                        Divider()
                        if item.status == .completed || item.status != .transcribing {
                            Button("Re-transcribe") {
                                appState.retranscribe(item)
                            }
                        }
                        Button("Remove", role: .destructive) {
                            appState.removeItem(item)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusIcon(_ item: TranscriptionItem) -> some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .transcribing:
            CircularProgressView(progress: item.progress)
                .frame(width: 18, height: 18)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func statusLabel(_ item: TranscriptionItem) -> String {
        switch item.status {
        case .pending: return "Pending"
        case .transcribing: return "\(Int(item.progress * 100))%"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let state = appState
        var handled = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    let ext = url.pathExtension.lowercased()
                    guard supportedExtensions.contains(ext) else { return }

                    DispatchQueue.main.async {
                        state.addFile(url: url)
                    }
                }
            }
        }
        return handled
    }

    // MARK: - File Picker

    private func handleMeetingEnded(appState: AppState, recorder: AudioRecorder) {
        NSApp.requestUserAttention(.criticalRequest)

        let alert = NSAlert()
        alert.messageText = "Meeting Ended"
        alert.informativeText = "The Zoom meeting appears to have ended. Would you like to stop recording?"
        alert.addButton(withTitle: "Stop Recording")
        alert.addButton(withTitle: "Continue Recording")
        alert.alertStyle = .informational
        alert.icon = AppIconGenerator.generate()

        // Show the alert window above all other windows (including Zoom)
        let panel = alert.window
        panel.level = .screenSaver
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Close the recording window
            NSApplication.shared.windows
                .first { $0.identifier?.rawValue == "recording" }?
                .close()
            let capturedSegments = appState.liveSegments
            let capturedText = appState.liveText
            let capturedTranslations = appState.liveTranslatedSegments
            let capturedLang: String? = !capturedTranslations.isEmpty
                ? UserDefaults.standard.string(forKey: "targetLanguage") : nil
            let hadLiveResults = appState.isLiveTranscribing && !capturedSegments.isEmpty

            appState.stopLiveTranscription()
            Task {
                let url = await recorder.stopRecording()
                if let url {
                    if hadLiveResults {
                        appState.addFileWithLiveResults(
                            url: url, segments: capturedSegments, fullText: capturedText,
                            translatedSegments: capturedTranslations, translationLanguage: capturedLang
                        )
                    } else {
                        appState.addFile(url: url)
                    }
                }
                await MainActor.run { recorder.state = .idle }
            }
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                appState.addFile(url: url)
            }
        }
    }
}

// MARK: - Circular Progress

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
