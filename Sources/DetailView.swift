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
                    ToolbarItem {
                        HStack(spacing: 4) {
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
                                .menuIndicator(.hidden)
                            }

                            Menu {
                                Button("Export as SRT...") { exportSRT(item) }
                                Button("Export as Text...") { exportText(item) }
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .menuIndicator(.hidden)
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
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var committedQuery = ""  // debounced query actually used for highlighting
    @State private var currentMatchIndex = 0
    @State private var cachedMatches: [(segmentIndex: Int, matchIndex: Int)] = []
    @State private var matchingSegmentIndices: Set<Int> = []  // segments that contain matches
    @State private var searchDebounceTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                searchBar
            }
            transcriptScrollView
        }
        .onKeyPress(keys: [.escape]) { _ in
            if showSearch {
                showSearch = false
                clearSearch()
                return .handled
            }
            return .ignored
        }
        .background {
            Button("") {
                showSearch.toggle()
                if showSearch {
                    isSearchFieldFocused = true
                } else {
                    clearSearch()
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .onChange(of: searchQuery) { _, newValue in
            searchDebounceTask?.cancel()
            let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                committedQuery = ""
                cachedMatches = []
                matchingSegmentIndices = []
                currentMatchIndex = 0
                return
            }
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                recomputeMatches(for: query)
            }
        }
    }

    private func clearSearch() {
        searchQuery = ""
        committedQuery = ""
        cachedMatches = []
        matchingSegmentIndices = []
        currentMatchIndex = 0
        searchDebounceTask?.cancel()
    }

    private func recomputeMatches(for query: String) {
        let lowered = query.lowercased()
        var results: [(segmentIndex: Int, matchIndex: Int)] = []
        var segIndices = Set<Int>()
        for (segIdx, segment) in item.segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespaces).lowercased()
            var matchNum = 0
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: lowered, range: searchRange) {
                results.append((segmentIndex: segIdx, matchIndex: matchNum))
                matchNum += 1
                searchRange = range.upperBound..<text.endIndex
            }
            if matchNum > 0 { segIndices.insert(segIdx) }
        }
        cachedMatches = results
        matchingSegmentIndices = segIndices
        committedQuery = query
        currentMatchIndex = 0
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.segments.enumerated()), id: \.offset) { index, segment in
                        segmentView(index: index, segment: segment)
                    }
                }
                .padding()
            }
            .onChange(of: audioPlayer.currentTime) { _, newTime in
                updateHighlight(time: newTime, proxy: proxy)
            }
            .onChange(of: currentMatchIndex) { _, _ in
                scrollToCurrentMatch(proxy: proxy)
            }
            .onChange(of: committedQuery) { _, _ in
                scrollToCurrentMatch(proxy: proxy)
            }
            .onAppear {
                audioPlayer.load(url: item.fileURL)
            }
        }
    }

    private func segmentView(index: Int, segment: TranscriptionSegment) -> some View {
        // Only pass search query to segments that actually have matches
        let hasMatch = matchingSegmentIndices.contains(index)
        let query = hasMatch ? committedQuery : ""
        let activeIndices = activeMatchIndicesForSegment(index)
        let translation = index < item.translatedSegments.count ? item.translatedSegments[index] : nil
        return SegmentRow(
            segment: segment,
            isCurrent: index == currentIndex,
            translation: translation,
            searchQuery: query,
            highlightedMatchIndices: activeIndices
        )
        .id(index)
        .onTapGesture {
            audioPlayer.load(url: item.fileURL)
            audioPlayer.seek(to: segment.start)
            audioPlayer.play()
        }
    }

    private func activeMatchIndicesForSegment(_ segmentIndex: Int) -> Set<Int> {
        guard !cachedMatches.isEmpty else { return [] }
        let safeIndex = min(currentMatchIndex, cachedMatches.count - 1)
        guard safeIndex >= 0 else { return [] }
        let current = cachedMatches[safeIndex]
        if current.segmentIndex == segmentIndex {
            return [current.matchIndex]
        }
        return []
    }

    @ViewBuilder
    private var searchBar: some View {
        VStack(spacing: 0) {
            SearchBarContent(
                searchQuery: $searchQuery,
                currentMatchIndex: $currentMatchIndex,
                isSearchFieldFocused: $isSearchFieldFocused,
                totalMatches: cachedMatches.count,
                onNavigate: { navigateMatch(forward: $0) },
                onDismiss: {
                    showSearch = false
                    clearSearch()
                }
            )
            Divider()
        }
    }

    private func navigateMatch(forward: Bool) {
        let total = cachedMatches.count
        guard total > 0 else { return }
        if forward {
            currentMatchIndex = (currentMatchIndex + 1) % total
        } else {
            currentMatchIndex = (currentMatchIndex - 1 + total) % total
        }
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard !cachedMatches.isEmpty else { return }
        let safeIndex = min(currentMatchIndex, cachedMatches.count - 1)
        guard safeIndex >= 0 else { return }
        let segIndex = cachedMatches[safeIndex].segmentIndex
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(segIndex, anchor: .center)
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
    var searchQuery: String = ""
    var highlightedMatchIndices: Set<Int> = []

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(formatTimestamp(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                highlightedText(segment.text.trimmingCharacters(in: .whitespaces))
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

    private func highlightedText(_ text: String) -> Text {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(text) }

        let loweredText = text.lowercased()
        let loweredQuery = query.lowercased()

        var ranges: [Range<String.Index>] = []
        var searchStart = loweredText.startIndex
        while searchStart < loweredText.endIndex,
              let range = loweredText.range(of: loweredQuery, range: searchStart..<loweredText.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }

        guard !ranges.isEmpty else { return Text(text) }

        var result = Text("")
        var currentPos = text.startIndex
        for (matchIdx, range) in ranges.enumerated() {
            if currentPos < range.lowerBound {
                result = result + Text(text[currentPos..<range.lowerBound])
            }
            let isActive = highlightedMatchIndices.contains(matchIdx)
            let attr = AttributedString(text[range])
            var container = AttributeContainer()
            container.backgroundColor = isActive ? .orange : .yellow.opacity(0.6)
            container.foregroundColor = .black
            let styledMatch = Text(attr.mergingAttributes(container))
            result = result + styledMatch
            currentPos = range.upperBound
        }
        if currentPos < text.endIndex {
            result = result + Text(text[currentPos..<text.endIndex])
        }
        return result
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Search Bar Content

struct SearchBarContent: View {
    @Binding var searchQuery: String
    @Binding var currentMatchIndex: Int
    var isSearchFieldFocused: FocusState<Bool>.Binding
    let totalMatches: Int
    let onNavigate: (Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            searchField
            if !searchQuery.isEmpty {
                matchCounter
                navigationButtons
            }
            dismissButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Find in transcript...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused(isSearchFieldFocused)
                .onSubmit {
                    onNavigate(true)
                }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var matchCounter: some View {
        let displayIndex = totalMatches > 0 ? min(currentMatchIndex + 1, totalMatches) : 0
        return Text("\(displayIndex)/\(totalMatches)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(minWidth: 40)
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button { onNavigate(false) } label: {
                Image(systemName: "chevron.up")
                    .font(.body.bold())
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(totalMatches == 0)

            Button { onNavigate(true) } label: {
                Image(systemName: "chevron.down")
                    .font(.body.bold())
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(totalMatches == 0)
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Text("Done")
                .font(.callout)
        }
        .buttonStyle(.plain)
    }
}
