import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppState.self) var appState
    @State private var isDropTargeted = false
    @State private var showRecordingSheet = false
    @State private var renamingItem: TranscriptionItem?
    @State private var renameText = ""

    private let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "mp4", "aac", "flac", "ogg", "wma", "aiff", "caf"
    ]

    var body: some View {
        @Bindable var appState = appState

        Group {
            if appState.items.isEmpty {
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
                Button {
                    showRecordingSheet = true
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
            }
        }
        .sheet(isPresented: $showRecordingSheet) {
            RecordingView()
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
        return List(selection: $state.selectedItemID) {
            ForEach(appState.items) { item in
                HStack(spacing: 8) {
                    statusIcon(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(statusLabel(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
