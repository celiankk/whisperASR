import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
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
    // Search results are computed once per debounced query (not per keystroke,
    // not per row per render) — scanning every transcript's full text on each
    // keystroke made typing janky with a large library.
    @State private var committedQuery = ""
    @State private var matchingIDs: Set<UUID> = []
    @State private var matchCounts: [UUID: Int] = [:]
    @State private var searchDebounceTask: Task<Void, Never>?

    // Kept in step with what the file picker (.audio/.movie) and AudioLoader
    // (AVFoundation, with an ffmpeg fallback for WebM/Opus/MKV) can handle.
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
                    Label("添加文件", systemImage: "plus")
                }
            }
            // 「选择」按钮已移至转录文件列表上方的搜索行（紧贴列表本体）。
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
            // Keep active search results in sync when items are added/removed.
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

    // MARK: - Empty State

    private var emptyDropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("拖放音频文件到此处")
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
                TextField("搜索转录…", text: $searchText)
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
                // 多选编辑入口（紧贴转录文件列表上方；编辑态操作在列表
                // 底部操作栏：全选/删除/完成）。
                if !isEditMode {
                    Button {
                        isEditMode = true
                    } label: {
                        Text("选择")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(appState.items.isEmpty)
                    .help("多选转录文件（批量删除）")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if isEditMode {
                // 编辑模式：显式勾选圈（macOS List 的 Set 多选要 ⌘/⇧ 点按，
                // 无可见勾选 UI），点行任意位置即切换勾选。
                List {
                    editModeRows
                }

                // 底部操作栏：全选 / 批量删除（带确认）/ 完成。
                HStack(spacing: 12) {
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
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            } else {
                List(selection: $state.selectedItemID) {
                    itemRows
                }
            }
        }
    }

    /// 编辑模式行：前置勾选圈 + 点行切换（不改动 selectedItemID，不跳详情）。
    @ViewBuilder
    private var editModeRows: some View {
        ForEach(filteredItems) { item in
            HStack(spacing: 8) {
                Image(systemName: selectedIDs.contains(item.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(item.id)
                                     ? Color.accentColor : Color.secondary)
                    .font(.title3)
                statusIcon(item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileURL.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusLabel(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selectedIDs.contains(item.id) {
                    selectedIDs.remove(item.id)
                } else {
                    selectedIDs.insert(item.id)
                }
            }
            .tag(item.id)
        }
    }

    /// 历史列表行（普通/编辑两种 List 共用，避免两份实现漂移）。
    @ViewBuilder
    private var itemRows: some View {
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
                        if !committedQuery.isEmpty {
                            let count = matchCounts[item.id] ?? 0
                            if count > 0 {
                                Text("\(count) 个匹配")
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
                // Buffer rows to push Remove well away from Re-transcribe,
                // so it can't be triggered by an accidental click.
                Divider()
                Button(" ") {}.disabled(true)
                Button(" ") {}.disabled(true)
                Divider()
                Button("移除", role: .destructive) {
                    itemPendingRemoval = item
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
        case .pending: return "等待中"
        case .transcribing: return "\(Int(item.progress * 100))%"
        case .completed: return "已完成"
        case .failed: return "失败"
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

// MARK: - Model Picker

/// Toolbar menu for choosing which model transcribes new audio.
/// 融合两类来源：ModelManager 下载目录（catalog）+ LocalModelManager 扫描到的
/// 本地自定义模型（如 LM Studio 模型目录），与 resolveModelPath 同一优先级：
/// 选中本地模型写入 modelPath（最高优先级）；选回 catalog/自动时清除 modelPath。
struct ModelPickerMenu: View {
    @State private var manager = ModelManager.shared
    @State private var localModels = LocalModelManager.shared

    /// 本地模型在 Picker 中的 tag 前缀（与 catalog fileName 区分）。
    private static let localTagPrefix = "local:"

    /// 当前生效的自定义模型路径（文件必须存在，否则视为未设置）。
    private var activeCustomPath: String {
        let path = UserDefaults.standard.string(forKey: "modelPath") ?? ""
        return (!path.isEmpty && FileManager.default.fileExists(atPath: path)) ? path : ""
    }

    /// 转录模型选择绑定：本地模型 tag = "local:<完整路径>"。
    private var mainModelSelection: Binding<String> {
        Binding(
            get: {
                let custom = activeCustomPath
                return custom.isEmpty ? manager.selectedFileName : Self.localTagPrefix + custom
            },
            set: { value in
                if value.hasPrefix(Self.localTagPrefix) {
                    let path = String(value.dropFirst(Self.localTagPrefix.count))
                    UserDefaults.standard.set(path, forKey: "modelPath")
                    AppLogger.shared.log(.model, "Quick switch to local model: \(path)")
                } else {
                    // 选回下载模型/自动：清除自定义路径（否则它优先级最高，选择不生效）。
                    UserDefaults.standard.set("", forKey: "modelPath")
                    manager.selectedFileName = value
                    AppLogger.shared.log(.model, "Quick switch to catalog model: \(value.isEmpty ? "自动" : value)")
                }
            }
        )
    }

    /// 菜单按钮标题：当前模型显示名。
    private var currentModelLabel: String {
        let custom = activeCustomPath
        if !custom.isEmpty {
            return (custom as NSString).deletingPathExtension
                .components(separatedBy: "/").last ?? "本地模型"
        }
        return manager.selectedModel?.displayName ?? "模型"
    }

    var body: some View {
        Menu {
            Picker("转录模型", selection: mainModelSelection) {
                Text("自动").tag("")
                ForEach(manager.downloadedModels) { model in
                    Text(model.displayName).tag(model.fileName)
                }
                if !localModels.models.isEmpty {
                    Divider()
                    ForEach(localModels.models) { model in
                        Text("\(model.name)（本地 \(model.sizeText)）")
                            .tag(Self.localTagPrefix + model.path)
                    }
                }
            }
            .pickerStyle(.inline)
            Picker("实时转录模型", selection: Binding(
                get: { manager.liveFileName },
                set: { manager.liveFileName = $0 }
            )) {
                Text("与转录模型相同").tag("")
                ForEach(manager.downloadedModels) { model in
                    Text(model.displayName).tag(model.fileName)
                }
            }
            .pickerStyle(.inline)
            Divider()
            SettingsLink {
                Text("管理模型…")
            }
        } label: {
            Label(currentModelLabel, systemImage: "cpu")
        }
        .help("用于转录的模型：\(currentModelLabel)")
        .onAppear {
            manager.refresh()
            localModels.scan()
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
