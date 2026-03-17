import SwiftUI
import UniformTypeIdentifiers

struct DetailView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioPlayerManager.self) var audioPlayer

    var body: some View {
        Group {
            if let item = appState.selectedItem {
                itemDetailView(item)
            } else {
                placeholderView
            }
        }
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("Select a transcription to view")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Item Detail

    @ViewBuilder
    private func itemDetailView(_ item: TranscriptionItem) -> some View {
        switch item.status {
        case .pending:
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Waiting to start...")
                    .foregroundStyle(.secondary)
            }

        case .transcribing:
            TranscribingView(item: item)

        case .completed:
            TranscriptContentView(item: item)
                .toolbar {
                    ToolbarItemGroup {
                        if item.isTranslating {
                            ProgressView()
                                .controlSize(.small)
                                .help("Translating...")
                        } else {
                            Menu {
                                ForEach(TargetLanguage.available) { lang in
                                    Button {
                                        appState.translateItem(item, targetLanguage: lang.id)
                                    } label: {
                                        HStack {
                                            Text(lang.name)
                                            if item.translationLanguage == lang.id && !item.translatedSegments.isEmpty {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                                if !item.translatedSegments.isEmpty {
                                    Divider()
                                    Button("Clear Translation") {
                                        appState.clearTranslation(item)
                                    }
                                }
                            } label: {
                                Label("Translate", systemImage: "character.bubble")
                            }
                        }

                        Menu {
                            Button("Export as SRT...") { exportSRT(item) }
                            Button("Export as Text...") { exportText(item) }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }

        case .failed(let error):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.red)
                Text("Transcription Failed")
                    .font(.headline)

                ScrollView {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 560)

                HStack(spacing: 12) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                    } label: {
                        Label("Copy Error", systemImage: "doc.on.doc")
                    }

                    Button {
                        appState.retranscribe(item)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .padding()
        }
    }

    // MARK: - Export

    private func exportSRT(_ item: TranscriptionItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = item.fileName
            .replacingOccurrences(of: ".\(item.fileURL.pathExtension)", with: ".srt")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let srt = generateSRT(segments: item.segments)
            try? srt.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportText(_ item: TranscriptionItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = item.fileName
            .replacingOccurrences(of: ".\(item.fileURL.pathExtension)", with: ".txt")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? item.fullText.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func generateSRT(segments: [TranscriptionSegment]) -> String {
        var lines: [String] = []
        for (i, seg) in segments.enumerated() {
            let start = formatSRTTime(seg.start)
            let end = formatSRTTime(seg.end ?? (seg.start + 5.0))
            lines.append("\(i + 1)")
            lines.append("\(start) --> \(end)")
            lines.append(seg.text.trimmingCharacters(in: .whitespaces))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func formatSRTTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

// MARK: - Transcribing Progress View

struct TranscribingView: View {
    let item: TranscriptionItem

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: item.progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)

            Text("\(Int(item.progress * 100))%")
                .font(.system(.title, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("Transcribing \(item.fileName)...")
                .foregroundStyle(.secondary)

            if let eta = estimatedTimeRemaining {
                Text(eta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }

    private var estimatedTimeRemaining: String? {
        guard let startTime = item.transcriptionStartTime,
              item.progress > 0.05 else {
            return "Estimating time remaining..."
        }
        let elapsed = Date().timeIntervalSince(startTime)
        let remaining = (elapsed / item.progress) - elapsed
        if remaining < 5 {
            return "Almost done..."
        } else if remaining < 60 {
            return "~\(Int(remaining))s remaining"
        } else {
            let mins = Int(remaining) / 60
            let secs = Int(remaining) % 60
            return "~\(mins)m \(secs)s remaining"
        }
    }
}

// MARK: - Transcript Content (with synced highlighting)

struct TranscriptContentView: View {
    let item: TranscriptionItem
    @Environment(AudioPlayerManager.self) var audioPlayer
    @State private var currentIndex: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.segments.enumerated()), id: \.offset) { index, segment in
                        SegmentRow(
                            segment: segment,
                            isCurrent: index == currentIndex,
                            translation: index < item.translatedSegments.count ? item.translatedSegments[index] : nil
                        )
                        .id(index)
                        .onTapGesture {
                            audioPlayer.load(url: item.fileURL)
                            audioPlayer.seek(to: segment.start)
                            audioPlayer.play()
                        }
                    }
                }
                .padding()
            }
            .onChange(of: audioPlayer.currentTime) { _, newTime in
                updateHighlight(time: newTime, proxy: proxy)
            }
            .onAppear {
                audioPlayer.load(url: item.fileURL)
            }
        }
    }

    private func updateHighlight(time: TimeInterval, proxy: ScrollViewProxy) {
        guard audioPlayer.currentURL == item.fileURL,
              audioPlayer.isPlaying || time > 0 else {
            currentIndex = nil
            return
        }

        let newIndex = item.segments.lastIndex { $0.start <= time }
        guard newIndex != currentIndex else { return }
        currentIndex = newIndex
        if let idx = newIndex {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }
}

// MARK: - Segment Row

struct SegmentRow: View {
    let segment: TranscriptionSegment
    let isCurrent: Bool
    var translation: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(formatTimestamp(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.text.trimmingCharacters(in: .whitespaces))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isCurrent ? 1.0 : 0.85)

                if let translation, !translation.isEmpty {
                    Text(translation)
                        .font(.callout)
                        .foregroundStyle(.blue.opacity(0.75))
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isCurrent
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .contentShape(Rectangle())
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
