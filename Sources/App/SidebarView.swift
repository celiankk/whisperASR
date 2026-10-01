import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 历史栏（原 SidebarView）。自绘双栏的左栏：固定 268pt，
/// 行模板移植 recent.design 的命名网格列（图标列 / 主文本 / 次文本 / 元数据列）。
///
/// 与旧实现的行为差异（有意为之）：
/// • 不再用 `List(selection:)`，选中改由点行直接写 `appState.selectedItemID`，
///   以换到「悬停淡出 + 露边圆角 + 激活游标」这些 List 里做不到的表达；
/// • 「添加文件」从窗口工具栏移到栏头（贴近列表本体）。
struct HistoryRail: View {
    @Environment(AppState.self) var appState
    @State private var isDropTargeted = false
    @State private var renamingItem: TranscriptionItem?
    @State private var renameText = ""
    @State private var itemPendingRemoval: TranscriptionItem?
    @State private var searchText = ""
    // 批量删除：编辑模式 + 多选集合 + 确认提示。
    @State private var isEditMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    // 悬停聚焦：hover 某行时其余行压到 Ink.dimmedSibling（站点 li:not(:hover) 手法）。
    @State private var hoveredID: UUID?
    // 搜索结果按防抖后的查询算一次（不是每次按键、也不是每行每次渲染）：
    // 大库下逐键全表扫描会让输入明显掉帧。
    @State private var committedQuery = ""
    @State private var matchingIDs: Set<UUID> = []
    @State private var matchCounts: [UUID: Int] = [:]
    @State private var searchDebounceTask: Task<Void, Never>?

    // 与文件选择器 (.audio/.movie) 和 AudioLoader（AVFoundation +
    // ffmpeg 兜底 WebM/Opus/MKV）能处理的格式保持一致。
    private let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "mp4", "m4v", "mov", "aac", "flac",
        "ogg", "oga", "opus", "webm", "mkv", "wma", "aiff", "aif", "caf"
    ]

    private var filteredItems: [TranscriptionItem] {
        guard !committedQuery.isEmpty else { return appState.items }
        return appState.items.filter { matchingIDs.contains($0.id) }
    }

    private func recomputeSearch(for query: String) {
        var ids = Set<UUID>()
        var counts: [UUID: Int] = [:]
        for item in appState.items {
            let text = item.fullText
            var count = 0
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: query, options: .caseInsensitive,
                                         range: searchStart..<text.endIndex) {
                count += 1
                searchStart = range.upperBound
            }
            if count > 0 { counts[item.id] = count }
            if count > 0 || item.fileName.localizedCaseInsensitiveContains(query) {
                ids.insert(item.id)
            }
        }
        matchingIDs = ids
        matchCounts = counts
        committedQuery = query
    }

    private func clearSearchResults() {
        committedQuery = ""
        matchingIDs = []
        matchCounts = [:]
    }

    var body: some View {
        VStack(spacing: 0) {
            railHeader
            searchField

            if appState.items.isEmpty && searchText.isEmpty {
                emptyDropZone
            } else {
                itemList
            }

            if isEditMode { editActionBar }
        }
        .background(Ink.faint)
        .overlay {
            if isDropTargeted {
                Corner.rect(Corner.small)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundStyle(Color.accentColor)
                    .background(Ink.soft(Color.accentColor, 0.06))
                    .clipShape(Corner.rect(Corner.small))
                    .padding(6)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                clearSearchResults()
                return
            }
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                recomputeSearch(for: query)
            }
        }
        .onChange(of: appState.items.count) { _, _ in
            // 增删条目后，让已生效的搜索结果同步跟上。
            if !committedQuery.isEmpty { recomputeSearch(for: committedQuery) }
        }
        .alert("重命名", isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingItem = nil }
            Button("重命名") {
                if let item = renamingItem {
                    appState.renameItem(item, to: renameText)
                }
                renamingItem = nil
            }
        } message: {
            Text("为此文件输入新名称。")
        }
        .confirmationDialog(
            "移除此转录？",
            isPresented: Binding(
                get: { itemPendingRemoval != nil },
                set: { if !$0 { itemPendingRemoval = nil } }
            ),
            presenting: itemPendingRemoval
        ) { item in
            Button("移除", role: .destructive) {
                appState.removeItem(item)
                itemPendingRemoval = nil
            }
            Button("取消", role: .cancel) { itemPendingRemoval = nil }
        } message: { item in
            Text(TranscriptionStore.isAppRecording(item.fileURL)
                ? "「\(item.fileURL.lastPathComponent)」将被移除，其录音将移至废纸篓。"
                : "「\(item.fileURL.lastPathComponent)」的转录将被移除。原始音频文件保留在磁盘上。")
        }
        .confirmationDialog(
            "批量删除 \(selectedIDs.count) 条转录？",
            isPresented: $showBatchDeleteConfirm
        ) {
            Button("删除 \(selectedIDs.count) 条", role: .destructive) {
                appState.removeItems(ids: selectedIDs)
                selectedIDs = []
                isEditMode = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所选转录将被移除；应用录制的音频将移至废纸篓（可恢复），导入的原始文件保留在磁盘上。进行中的转录会自动跳过。")
        }
    }

    // MARK: - 栏头

    private var railHeader: some View {
        HStack(spacing: Metrics.sm) {
            Text("转录历史")
                .font(Type.mono(Type.label, weight: .medium))
                .tracking(Type.labelTracking)
                .foregroundStyle(Ink.secondary)
            if !appState.items.isEmpty {
                Text("\(appState.items.count)")
                    .font(Type.mono(Type.micro, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Corner.rect(Corner.tiny).fill(Ink.subtle))
            }
            if appState.isLiveTranscribing {
                HStack(spacing: 4) {
                    ActiveDot(active: true, color: Palette.live)
                    Text("实时")
                        .font(Type.mono(Type.micro, weight: .medium))
                        .foregroundStyle(Palette.live)
                }
            }
            Spacer(minLength: 0)

            Button(action: openFilePicker) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(GhostButtonStyle(size: 24))
            .help("添加音频/视频文件")

            Button {
                isEditMode.toggle()
                if !isEditMode { selectedIDs = [] }
            } label: {
                Text(isEditMode ? "完成" : "选择")
                    .font(Type.text(Type.caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEditMode ? Color.accentColor : Ink.secondary)
            .disabled(appState.items.isEmpty)
            .motionAnimation(Motion.standard(0.18), value: isEditMode)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, Metrics.xs)
    }

    private var searchField: some View {
        HStack(spacing: Metrics.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
            TextField("搜索转录…", text: $searchText)
                .textFieldStyle(.plain)
                .font(Type.text(Type.caption))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Corner.rect(Corner.small).fill(Ink.subtle))
        .overlay(Corner.rect(Corner.small).strokeBorder(Ink.hairline, lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.bottom, Metrics.xs)
    }

    // MARK: - Empty State

    private var emptyDropZone: some View {
        VStack(spacing: Metrics.lg) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Ink.secondary)
            Text("拖放音频文件到此处")
                .font(Type.text(Type.emphasis))
                .titleTracking(Type.emphasis)
                .foregroundStyle(Ink.secondary)
            Text("MP3 · WAV · M4A · MP4 · AAC · FLAC")
                .font(Type.mono(Type.micro))
                .tracking(Type.labelTracking)
                .foregroundStyle(Ink.secondary.opacity(0.7))
            Button("选择文件…", action: openFilePicker)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Item List

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredItems) { item in
                    RailRow(
                        item: item,
                        isSelected: appState.selectedItemID == item.id,
                        isEditing: isEditMode,
                        isChecked: selectedIDs.contains(item.id),
                        matchCount: matchCounts[item.id] ?? 0,
                        dimmed: hoveredID != nil && hoveredID != item.id,
                        onTap: {
                            if isEditMode {
                                if selectedIDs.contains(item.id) {
                                    selectedIDs.remove(item.id)
                                } else {
                                    selectedIDs.insert(item.id)
                                }
                            } else {
                                appState.selectedItemID = item.id
                            }
                        }
                    )
                    .onHover { inside in
                        // 触屏/无指针环境不会触发，无需 hover 媒体查询。
                        hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID)
                    }
                    .contextMenu { rowContextMenu(item) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, Metrics.xs)
        }
        .scrollIndicators(.automatic)
        .edgeFadeVertical(24)
    }

    @ViewBuilder
    private func rowContextMenu(_ item: TranscriptionItem) -> some View {
        Button("重命名") {
            renameText = item.fileURL.deletingPathExtension().lastPathComponent
            renamingItem = item
        }
        Button("复制文件") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([item.fileURL as NSURL])
        }
        Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
        }
        Divider()
        if item.status != .transcribing {
            Button("重新转录") {
                appState.retranscribe(item)
            }
        }
        // 缓冲项：把「移除」推离「重新转录」，避免误点。
        Divider()
        Button(" ") {}.disabled(true)
        Button(" ") {}.disabled(true)
        Divider()
        // 转录进行中不提供「移除」：完成回调会回写记录，删除即复活。
        // 管理器层同样拒绝（双保险），此处直接隐藏入口避免误操作。
        if item.status != .transcribing {
            Button("移除", role: .destructive) {
                itemPendingRemoval = item
            }
        }
    }

    // MARK: - 编辑模式底部动作条

    private var editActionBar: some View {
        HStack(spacing: Metrics.lg) {
            Button(selectedIDs.count == filteredItems.count && !filteredItems.isEmpty
                   ? "全不选" : "全选") {
                if selectedIDs.count == filteredItems.count {
                    selectedIDs = []
                } else {
                    selectedIDs = Set(filteredItems.map(\.id))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Spacer()

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("删除(\(selectedIDs.count))", systemImage: "trash")
            }
            .disabled(selectedIDs.isEmpty)

            Button("完成") {
                isEditMode = false
                selectedIDs = []
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .font(Type.text(Type.caption))
        .padding(.horizontal, 12)
        .padding(.vertical, Metrics.md)
        .overlay(alignment: .top) { HairlineDivider() }
        .background(Ink.faint)
    }

    // MARK: - Helpers

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

// MARK: - 历史行

/// 单行：状态图标 · 文件名/摘要 · 等宽元数据。悬停淡出由父级驱动。
private struct RailRow: View {
    let item: TranscriptionItem
    let isSelected: Bool
    let isEditing: Bool
    let isChecked: Bool
    let matchCount: Int
    let dimmed: Bool
    /// 点行回调：编辑态 = 切换勾选，普通态 = 选中该条目（由父级决定，
    /// 子视图不反向持有父状态）。
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.md) {
            if isEditing {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isChecked ? Color.accentColor : Ink.secondary)
            } else {
                StatusMark(item: item)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileURL.deletingPathExtension().lastPathComponent)
                    .font(Type.text(Type.caption, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let snippet = snippetText {
                    Text(snippet)
                        .font(Type.text(Type.micro))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Metrics.xs)

            trailingMeta
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .leading) {
                Corner.rect(Corner.small)
                    .fill(isSelected ? Ink.active : (hovering ? Ink.hover : .clear))
                if isSelected && !isEditing {
                    // 激活条：2pt 短条而不是整行实色块。
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 16)
                        .padding(.leading, 3)
                }
            }
        )
        .contentShape(Corner.rect(Corner.small))
        .opacity(dimmed ? Ink.dimmedSibling : 1)
        .motionAnimation(Motion.standard(0.18), value: dimmed)
        .motionAnimation(Motion.standard(0.18), value: hovering)
        .motionAnimation(Motion.standard(0.18), value: isSelected)
        .onTapGesture(perform: onTap)
        .onHover { inside in hovering = inside }
    }

    private var snippetText: String? {
        guard !isEditing else { return nil }
        let text = item.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(48))
    }

    @ViewBuilder
    private var trailingMeta: some View {
        switch item.status {
        case .transcribing:
            Text("\(Int(item.progress * 100))%")
                .font(Type.mono(Type.micro, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .contentTransition(.numericText())
        case .failed:
            Text("失败")
                .font(Type.mono(Type.micro, weight: .medium))
                .foregroundStyle(Palette.danger)
        case .pending:
            Text("排队")
                .font(Type.mono(Type.micro))
                .foregroundStyle(Ink.secondary)
        case .completed:
            if matchCount > 0 {
                Text("\(matchCount) 处")
                    .font(Type.mono(Type.micro, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(RailRow.dayString(item.dateAdded))
                    .font(Type.mono(Type.micro))
                    .foregroundStyle(Ink.secondary)
            }
        }
    }

    static func dayString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}

// MARK: - 状态标记

/// 状态图标：进行中用呼吸环（方案 8），其余用低饱和符号。
struct StatusMark: View {
    let item: TranscriptionItem

    var body: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
                .frame(width: 16, height: 16)
        case .transcribing:
            CircularProgressView(progress: item.progress)
                .frame(width: 16, height: 16)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ok.opacity(0.85))
                .frame(width: 16, height: 16)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.danger.opacity(0.9))
                .frame(width: 16, height: 16)
        }
    }
}
