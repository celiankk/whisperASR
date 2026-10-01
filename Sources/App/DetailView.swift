import AVFoundation
import SwiftUI

/// 转录工作台（主窗口右栏）。原 DetailView 重构版：
/// • 顶部工作条：标题（负字距）+ 中性徽章（时长/日期/段数/语言）+ 动作；
/// • 转录正文：分段行 + 共享几何「游标」高亮（随播放滑动）；
/// • 播放器悬浮在右栏底部（PlayerCapsule），不再是底部常驻条。
struct DetailView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioPlayerManager.self) var audioPlayer
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showTimestamps = true
    @State private var translationOnly = false
    @State private var showSearch = false
    @State private var minutesPromptStore = MinutesPromptStore.shared

    var body: some View {
        Group {
            if let item = appState.selectedItem {
                itemDetailView(item)
            } else {
                PlaceholderView(
                    onRecord: startRecording,
                    onImport: openFileImportPanel,
                    onShowSubtitle: showSubtitleOverlay
                )
            }
        }
        .onAppear {
            // 历史条目懒加载：打开详情时载入完整 segments/译文。
            appState.selectedItem?.hydrateTranscriptIfNeeded()
        }
        .onChange(of: appState.selectedItem?.id) { _, _ in
            showSearch = false
            appState.selectedItem?.hydrateTranscriptIfNeeded()
        }
    }

    // MARK: - 状态路由

    @ViewBuilder
    private func itemDetailView(_ item: TranscriptionItem) -> some View {
        switch item.status {
        case .pending:
            WorkspaceShell(item: item) {
                PendingStateView()
            }

        case .transcribing:
            WorkspaceShell(item: item) {
                TranscribingView(item: item)
            }

        case .failed(let error):
            WorkspaceShell(item: item) {
                FailedStateView(item: item, error: error) {
                    appState.retranscribe(item)
                }
            }

        case .completed:
            WorkspaceShell(item: item, actions: .init(
                item: item,
                showSearch: $showSearch,
                showTimestamps: $showTimestamps,
                translationOnly: $translationOnly,
                onTranslate: { appState.translateItem(item, targetLanguage: $0) },
                onClearTranslation: { appState.clearTranslation(item) },
                minutesPromptStore: minutesPromptStore,
                openWindow: openWindow,
                openSettings: { openSettings() }
            )) {
                TranscriptContentView(
                    item: item,
                    showSearch: $showSearch,
                    showTimestamps: showTimestamps,
                    translationOnly: translationOnly
                )
            }
            .overlay(alignment: .bottom) {
                PlayerCapsule()
                    .padding(.horizontal, Metrics.xl)
            }
        }
    }

    // MARK: - 占位页动作

    private func startRecording() {
        // 录制入口授权闸：未授权时直接跳授权流程。
        guard PermissionGuidePanelController.shared.authorizeForRecording() else { return }
        FloatingLetterOverlayHost.shared.startRecordingFlow(
            appState: appState, recorder: recorder
        ) {
            FloatingLetterOverlayHost.shared.dismiss()
        }
    }

    private func showSubtitleOverlay() {
        // 展示字幕浮层（不进入录制流程；录制仍从录制入口开始）。
        FloatingLetterOverlayHost.shared.present(
            appState: appState, recorder: recorder
        )
    }

    private func openFileImportPanel() {
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

// MARK: - 工作台外壳（标题条 + 内容区）

/// 右栏统一外壳：标题条在上，内容由各状态填充；
/// 未完成状态不给动作（传 nil 时标题条只展示徽章）。
private struct WorkspaceShell<Content: View>: View {
    let item: TranscriptionItem
    var actions: WorkspaceActions?
    var content: Content

    /// 音频总时长：点开条目后异步量一次（AVURLAsset.load，失败不显示）。
    @State private var duration: Double?

    init(item: TranscriptionItem, actions: WorkspaceActions? = nil,
         @ViewBuilder content: () -> Content) {
        self.item = item
        self.actions = actions
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: item.id) {
            duration = nil
            guard item.fileURL.isFileURL else { return }
            let asset = AVURLAsset(url: item.fileURL)
            let seconds = try? await asset.load(.duration).seconds
            guard !Task.isCancelled else { return }
            duration = (seconds?.isFinite ?? false) ? seconds : nil
        }
    }

    private var title: String {
        item.fileURL.deletingPathExtension().lastPathComponent
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Metrics.lg) {
            VStack(alignment: .leading, spacing: Metrics.xs) {
                Text(title)
                    .font(Type.text(Type.title, weight: .semibold))
                    .titleTracking(Type.title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: Metrics.sm) {
                    if let duration {
                        Text(duration.badgeString)
                            .font(Type.mono(Type.micro))
                            .foregroundStyle(Ink.secondary)
                    }
                    if !item.segments.isEmpty {
                        Text("\(item.segments.count) 段")
                            .font(Type.mono(Type.micro))
                            .foregroundStyle(Ink.secondary)
                    }
                    Text(item.dateAdded.formatted(.dateTime.year().month().day()))
                        .font(Type.mono(Type.micro))
                        .foregroundStyle(Ink.secondary)
                    if let lang = item.translationLanguage, !item.translatedSegments.isEmpty {
                        TintBadge(text: lang.uppercased(), color: Palette.translation)
                    }
                    statusBadge
                }
            }

            Spacer(minLength: Metrics.xl)

            if let actions { actionsRow(actions) }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.lg)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .pending:
            TintBadge(text: "排队", color: Ink.secondary)
        case .transcribing:
            TintBadge(text: "转录中", color: Color.accentColor)
        case .completed:
            EmptyView()
        case .failed:
            TintBadge(text: "失败", color: Palette.danger)
        }
    }

    @ViewBuilder
    private func actionsRow(_ a: WorkspaceActions) -> some View {
        HStack(spacing: Metrics.xs) {
            ModelPickerMenu()

            if a.isTranslating {
                ProgressView()
                    .controlSize(.small)
                    .help("翻译中…")
            } else {
                IconButtonMenu(systemImage: "character.bubble", help: "翻译") {
                    ForEach(TargetLanguage.available) { lang in
                        Button {
                            a.onTranslate(lang.id)
                        } label: {
                            HStack {
                                Text(lang.nativeName)
                                if item.translationLanguage == lang.id
                                    && !item.translatedSegments.isEmpty {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if !item.translatedSegments.isEmpty {
                        Divider()
                        Button("清除翻译", action: a.onClearTranslation)
                    }
                }
            }

            if !item.translatedSegments.isEmpty {
                GhostIconButton(
                    systemImage: a.translationOnly ? "eye.fill" : "eye",
                    help: a.translationOnly ? "显示原文和翻译" : "仅显示翻译",
                    action: { a.translationOnly.toggle() }
                )
            }

            GhostIconButton(
                systemImage: a.showTimestamps ? "clock.fill" : "clock",
                help: a.showTimestamps ? "隐藏时间戳" : "显示时间戳",
                action: { a.showTimestamps.toggle() }
            )

            IconButtonMenu(systemImage: "list.bullet.clipboard", help: "使用提示词生成会议纪要") {
                ForEach(a.minutesPromptStore.prompts) { prompt in
                    Button {
                        TranscriptActions.generateMinutes(
                            item, prompt: prompt,
                            store: a.minutesPromptStore, openWindow: a.openWindow
                        )
                    } label: {
                        HStack {
                            Text(prompt.name)
                            if a.minutesPromptStore.selectedPromptID == prompt.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                if TranscriptActions.hasGeneratedMinutes(for: item) {
                    Button("显示纪要") { a.openWindow(id: "minutes") }
                }
                Button("编辑提示词…", action: a.openSettings)
            }

            IconButtonMenu(systemImage: "square.and.arrow.up", help: "导出") {
                Button("复制内容") { TranscriptActions.copyContent(item) }
                if !item.translatedSegments.isEmpty {
                    Button("复制翻译") { TranscriptActions.copyTranslation(item) }
                }
                Divider()
                Button("导出文本…") { TranscriptActions.exportText(item) }
                if !item.translatedSegments.isEmpty {
                    Button("导出翻译…") { TranscriptActions.exportTranslation(item) }
                }
                if !item.segments.isEmpty {
                    Menu("导出字幕") {
                        ForEach(SubtitleFormat.allCases) { format in
                            Button("\(format.displayName)…") {
                                TranscriptActions.exportSubtitles(item, format: format)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 工作条动作的打包参数（避免 WorkspaceShell 泛型参数爆炸）。
private struct WorkspaceActions {
    @Binding var showSearch: Bool
    @Binding var showTimestamps: Bool
    @Binding var translationOnly: Bool
    var onTranslate: (String) -> Void
    var onClearTranslation: () -> Void
    var minutesPromptStore: MinutesPromptStore
    var openWindow: OpenWindowAction
    var openSettings: () -> Void

    var isTranslating: Bool = false

    init(item: TranscriptionItem,
         showSearch: Binding<Bool>,
         showTimestamps: Binding<Bool>,
         translationOnly: Binding<Bool>,
         onTranslate: @escaping (String) -> Void,
         onClearTranslation: @escaping () -> Void,
         minutesPromptStore: MinutesPromptStore,
         openWindow: OpenWindowAction,
         openSettings: @escaping () -> Void) {
        self._showSearch = showSearch
        self._showTimestamps = showTimestamps
        self._translationOnly = translationOnly
        self.onTranslate = onTranslate
        self.onClearTranslation = onClearTranslation
        self.minutesPromptStore = minutesPromptStore
        self.openWindow = openWindow
        self.openSettings = openSettings
        self.isTranslating = item.isTranslating
    }
}

/// ghost 图标按钮。
private struct GhostIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
        }
        .buttonStyle(GhostButtonStyle(size: 28))
        .help(help)
    }
}

/// 图标样式的 Menu（边框去 chrome + 发丝底，与 ghost 按钮同一视觉家族）。
private struct IconButtonMenu<MenuContent: View>: View {
    let systemImage: String
    let help: String
    var content: () -> MenuContent

    init(systemImage: String, help: String, @ViewBuilder content: @escaping () -> MenuContent) {
        self.systemImage = systemImage
        self.help = help
        self.content = content
    }

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

// MARK: - 占位页

/// 未选中条目的占位页（首次启动即此页）：
/// 品牌区 + 三张可点的 ghost 卡（点击直接调用对应功能）。
private struct PlaceholderView: View {
    let onRecord: () -> Void
    let onImport: () -> Void
    let onShowSubtitle: () -> Void

    var body: some View {
        VStack(spacing: Metrics.xxxl) {
            VStack(spacing: Metrics.md) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                Text("声记 SonicScribe")
                    .font(Type.text(Type.display, weight: .semibold))
                    .titleTracking(Type.display)
                Text("实时语音转字幕 · 多引擎识别 · 实时翻译")
                    .font(Type.text(Type.body))
                    .foregroundStyle(Ink.secondary)
            }
            .padding(.top, 40)

            HStack(spacing: Metrics.lg) {
                FeatureCard(
                    icon: "record.circle", tint: Palette.live,
                    title: "开始录制",
                    detail: "工具栏录制按钮，实时出字幕与翻译",
                    action: onRecord
                )
                FeatureCard(
                    icon: "square.and.arrow.down", tint: Palette.info,
                    title: "导入文件",
                    detail: "拖放音频到左侧列表，批量文件转录",
                    action: onImport
                )
                FeatureCard(
                    icon: "captions.bubble", tint: Palette.ok,
                    title: "实时字幕",
                    detail: "字幕浮层可穿透、缩放，支持 OBS 采集",
                    action: onShowSubtitle
                )
            }
            .padding(.horizontal, Metrics.xxxl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 功能引导卡：ghost 变体（透明底 + hover 淡底 + 发丝环），点击即调用。
private struct FeatureCard: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Corner.rect(Corner.small).fill(Ink.soft(tint, 0.12)))

            Text(title)
                .font(Type.text(Type.emphasis, weight: .medium))

            Text(detail)
                .font(Type.text(Type.caption))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.lg)
        .background(
            Corner.rect(Corner.card)
                .fill(hovering ? Ink.hover : Ink.faint)
        )
        .overlay(Corner.rect(Corner.card).strokeBorder(Ink.hairline, lineWidth: 0.5))
        .contentShape(Corner.rect(Corner.card))
        .onHover { inside in
            hovering = inside
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .motionAnimation(Motion.standard(0.2), value: hovering)
        .onTapGesture(perform: action)
    }
}

// MARK: - 各状态内容

private struct PendingStateView: View {
    var body: some View {
        VStack(spacing: Metrics.md) {
            Image(systemName: "clock")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Ink.secondary)
            Text("等待开始…")
                .font(Type.text(Type.body))
                .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 转录中：细进度条 + 等宽百分比滚动 + ETA。
struct TranscribingView: View {
    let item: TranscriptionItem

    var body: some View {
        VStack(spacing: Metrics.xl) {
            LinearProgressBar(progress: item.progress, showsValue: true)
                .frame(maxWidth: 320)

            Text("正在转录 \(item.fileName)…")
                .font(Type.text(Type.caption))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let eta = estimatedTimeRemaining {
                Text(eta)
                    .font(Type.mono(Type.micro))
                    .foregroundStyle(Ink.secondary.opacity(0.8))
                    .contentTransition(.numericText())
                    .animation(Motion.anim(Motion.standard(0.25)), value: eta)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var estimatedTimeRemaining: String? {
        guard let startTime = item.transcriptionStartTime,
              item.progress > 0.05 else {
            return "估算剩余时间…"
        }
        let elapsed = Date().timeIntervalSince(startTime)
        let remaining = (elapsed / item.progress) - elapsed
        if remaining < 5 {
            return "即将完成…"
        } else if remaining < 60 {
            return "还剩 ~\(Int(remaining)) 秒"
        } else {
            let mins = Int(remaining) / 60
            let secs = Int(remaining) % 60
            return "还剩 ~\(mins) 分 \(secs) 秒"
        }
    }
}

private struct FailedStateView: View {
    let item: TranscriptionItem
    let error: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Metrics.xl) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.danger)
            Text("转录失败")
                .font(Type.text(Type.emphasis, weight: .medium))

            ScrollView {
                Text(error)
                    .font(Type.mono(Type.micro))
                    .foregroundStyle(Ink.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.md)
            }
            .frame(maxHeight: 220)
            .background(Corner.rect(Corner.small).fill(Ink.subtle))
            .overlay(Corner.rect(Corner.small).strokeBorder(Ink.hairline, lineWidth: 0.5))
            .frame(maxWidth: 560)

            HStack(spacing: Metrics.lg) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                } label: {
                    Label("复制错误", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onRetry()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - 转录正文（含播放跟随高亮）

/// 分段正文：搜索条（浮动）+ 滚动区（上下渐隐）+ 当前句「游标」高亮。
struct TranscriptContentView: View {
    let item: TranscriptionItem
    @Environment(AudioPlayerManager.self) var audioPlayer
    @State private var currentIndex: Int?
    @Binding var showSearch: Bool
    @State private var searchQuery = ""
    @State private var committedQuery = ""  // 防抖后真正用于高亮的查询
    @State private var currentMatchIndex = 0
    @State private var cachedMatches: [(segmentIndex: Int, matchIndex: Int)] = []
    @State private var matchingSegmentIndices: Set<Int> = []
    @State private var searchDebounceTask: Task<Void, Never>?
    var showTimestamps: Bool = true
    var translationOnly: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @Namespace private var cursorNS

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
                return .handled
            }
            return .ignored
        }
        .background {
            Button("") {
                showSearch.toggle()
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
        .onChange(of: showSearch) { _, newValue in
            if newValue {
                isSearchFieldFocused = true
            } else {
                clearSearch()
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
        var results: [(segmentIndex: Int, matchIndex: Int)] = []
        var segIndices = Set<Int>()
        for (segIdx, segment) in item.segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            var matchNum = 0
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: query, options: .caseInsensitive, range: searchRange) {
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
                LazyVStack(alignment: .leading, spacing: 2) {
                    // indices 直接遍历（Range<Int> 零拷贝）：Array(enumerated())
                    // 会在每次 body 重算时全量拷贝段数组（数千段 × 播放期 10Hz
                    // 重算 = 每秒上万次元素拷贝）；id 用位置（段数组渲染期不可变，
                    // 与既有 offset 索引体系一致）。
                    ForEach(item.segments.indices, id: \.self) { index in
                        segmentView(index: index, segment: item.segments[index])
                    }
                }
                // 底部留出悬浮胶囊的高度，最后一行不被盖住。
                .padding(.top, Metrics.lg)
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 84)
            }
            .edgeFadeVertical(EdgeFade.length)
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
            // 切换历史条目必须重载播放器：TranscriptContentView 在条目之间
            // 被复用（无 .id(item.id)），onAppear 不会重跑 —— 否则播放胶囊
            // 仍指向上一段录音，点新条目的段落才切过去，暂停/播放操作的是
            // 上一条音频。
            .onChange(of: item.id) { _, _ in
                currentIndex = nil
                audioPlayer.load(url: item.fileURL)
            }
        }
    }

    private func segmentView(index: Int, segment: TranscriptionSegment) -> some View {
        // 只把搜索词传给真正有命中的段。
        let hasMatch = matchingSegmentIndices.contains(index)
        let query = hasMatch ? committedQuery : ""
        let activeIndices = activeMatchIndicesForSegment(index)
        let translation = index < item.translatedSegments.count ? item.translatedSegments[index] : nil
        return SegmentRow(
            segment: segment,
            isCurrent: index == currentIndex,
            translation: translation,
            searchQuery: query,
            highlightedMatchIndices: activeIndices,
            showTimestamp: showTimestamps,
            translationOnly: translationOnly,
            cursorNamespace: cursorNS
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
        SearchBarContent(
            searchQuery: $searchQuery,
            currentMatchIndex: $currentMatchIndex,
            isSearchFieldFocused: $isSearchFieldFocused,
            totalMatches: cachedMatches.count,
            onNavigate: { navigateMatch(forward: $0) },
            onDismiss: { showSearch = false }
        )
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.sm)
        .overlay(alignment: .bottom) { HairlineDivider() }
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
        Motion.run(Motion.inOut(0.3)) {
            proxy.scrollTo(segIndex, anchor: .center)
        }
    }

    /// 播放期二分定位当前段（段按 start 有序，每个 tick 跑一次）。
    private func segmentIndex(at time: TimeInterval) -> Int? {
        var low = 0
        var high = item.segments.count - 1
        var result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if item.segments[mid].start <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    private func updateHighlight(time: TimeInterval, proxy: ScrollViewProxy) {
        guard audioPlayer.currentURL == item.fileURL,
              audioPlayer.isPlaying || time > 0 else {
            currentIndex = nil
            return
        }

        let newIndex = segmentIndex(at: time)
        guard newIndex != currentIndex else { return }
        Motion.run(Motion.standard(0.26)) {
            currentIndex = newIndex
            if let idx = newIndex {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }
}

// MARK: - 分段行

/// 一行转录：等宽时间戳列 + 正文/译文列。
/// 当前行的高亮走 matchedGeometryEffect「游标」：同一 id 每次只出现在
/// 当前行上，行间切换时 SwiftUI 会做 frame 过渡（替代瞬变的实色块）。
struct SegmentRow: View {
    let segment: TranscriptionSegment
    let isCurrent: Bool
    var translation: String? = nil
    var searchQuery: String = ""
    var highlightedMatchIndices: Set<Int> = []
    var showTimestamp: Bool = true
    var translationOnly: Bool = false
    var cursorNamespace: Namespace.ID

    @AppStorage("transcriptFontSize") private var transcriptFontSizeRaw = TranscriptFontSize.normal.rawValue
    private var fontSize: TranscriptFontSize { TranscriptFontSize(rawValue: transcriptFontSizeRaw) ?? .normal }

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.lg) {
            if showTimestamp {
                Text(formatTimestamp(segment.start))
                    .font(fontSize.timestampFont)
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 55, alignment: .trailing)
                    .padding(.top, 7)
            }

            VStack(alignment: .leading, spacing: 2) {
                if !translationOnly {
                    highlightedText(segment.text.trimmingCharacters(in: .whitespaces))
                        .font(fontSize.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.82))
                }

                if let translation, !translation.isEmpty {
                    Text(translation)
                        .font(translationOnly ? fontSize.bodyFont : fontSize.translationFont)
                        .foregroundStyle(Palette.translation)
                        .italic(translationOnly ? false : true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Metrics.md)
            .padding(.vertical, Metrics.sm)
        }
        .background {
            ZStack {
                Corner.rect(Corner.small)
                    .fill(hovering && !isCurrent ? Ink.hover : .clear)
                if isCurrent {
                    Corner.rect(Corner.small)
                        .fill(Ink.soft(Color.accentColor, 0.10))
                        .matchedGeometryEffect(id: "transcriptCursor", in: cursorNamespace)
                }
            }
        }
        .contentShape(Corner.rect(Corner.small))
        .onHover { hovering = $0 }
        .motionAnimation(Motion.standard(0.18), value: hovering)
    }

    private func highlightedText(_ text: String) -> Text {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(text) }

        // 在原字符串上做不区分大小写搜索。lowercased() 副本上算 range 再回切
        // 会崩（如 "İ" 小写后长度变化：i + 组合点）。
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
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
            container.backgroundColor = isActive
                ? Color.orange.opacity(0.85)
                : Color.yellow.opacity(0.35)
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

// MARK: - 搜索条

struct SearchBarContent: View {
    @Binding var searchQuery: String
    @Binding var currentMatchIndex: Int
    var isSearchFieldFocused: FocusState<Bool>.Binding
    let totalMatches: Int
    let onNavigate: (Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Metrics.md) {
            searchField
            if !searchQuery.isEmpty {
                matchCounter
                navigationButtons
            }
            dismissButton
        }
    }

    private var searchField: some View {
        HStack(spacing: Metrics.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
            TextField("在转录中查找…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(Type.text(Type.caption))
                .focused(isSearchFieldFocused)
                .onSubmit { onNavigate(true) }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.md)
        .padding(.vertical, 5)
        .background(Corner.rect(Corner.small).fill(Ink.subtle))
        .overlay(Corner.rect(Corner.small).strokeBorder(Ink.hairline, lineWidth: 0.5))
    }

    private var matchCounter: some View {
        let displayIndex = totalMatches > 0 ? min(currentMatchIndex + 1, totalMatches) : 0
        return Text("\(displayIndex)/\(totalMatches)")
            .font(Type.mono(Type.micro, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .contentTransition(.numericText())
            .animation(Motion.anim(Motion.standard(0.2)), value: currentMatchIndex)
            .frame(minWidth: 40)
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button { onNavigate(false) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(GhostButtonStyle(size: 24))
            .disabled(totalMatches == 0)

            Button { onNavigate(true) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(GhostButtonStyle(size: 24))
            .disabled(totalMatches == 0)
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Text("完成")
                .font(Type.text(Type.caption))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

// MARK: - 工具

extension Double {
    /// 3661.2 → "1:01:01"；96.5 → "1:36"（徽章用）。
    var badgeString: String {
        guard isFinite, !isNaN, self >= 0 else { return "--:--" }
        let total = Int(self)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
