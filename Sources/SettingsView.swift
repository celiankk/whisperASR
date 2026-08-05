import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("transcriptFontSize") private var transcriptFontSize = TranscriptFontSize.normal.rawValue
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("targetLanguage") private var targetLanguage = ""
    @AppStorage("translationEndpoint") private var translationEndpoint = ""
    @AppStorage("translationAPIKey") private var translationAPIKey = ""
    @AppStorage("translationModel") private var translationModel = ""

    // Local OpenAI-compatible API server
    @AppStorage(APIServer.enabledKey) private var apiServerEnabled = false
    @AppStorage(APIServer.portKey) private var apiServerPort = 8080
    @AppStorage(APIServer.tokenKey) private var apiServerToken = ""
    @AppStorage(APIServer.allowLANKey) private var apiServerAllowLAN = false
    @AppStorage(APIServer.verboseLogKey) private var apiServerVerboseLog = false
    @State private var apiServer = APIServer.shared

    @State private var verifyInFlight = false
    @State private var verifyResult: VerifyResult? = nil

    // Backup & restore
    @State private var backupStatus: BackupStatus? = nil
    @State private var pendingRestore: BackupService.BackupFile? = nil
    @State private var showRestoreConfirm = false

    // Meeting minutes
    @State private var minutesStore = MinutesPromptStore.shared
    @AppStorage(MinutesPromptStore.contextTokensKey) private var minutesContextTokens = MinutesPromptStore.defaultContextTokens
    @State private var editingPrompt: MinutesPrompt? = nil
    @State private var promptPendingDelete: MinutesPrompt? = nil

    private enum VerifyResult {
        case success(String)
        case failure(String)
    }

    private enum BackupStatus {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section("外观") {
                Picker("转录字体大小", selection: $transcriptFontSize) {
                    ForEach(TranscriptFontSize.allCases, id: \.rawValue) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("翻译") {
                Picker("目标语言", selection: $targetLanguage) {
                    Text("关闭").tag("")
                    ForEach(TargetLanguage.available) { lang in
                        Text(lang.nativeName).tag(lang.id)
                    }
                }
                Text("使用下方配置的 OpenAI 兼容 API 将实时转录翻译为此语言。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI API") {
                TextField("API 端点", text: $translationEndpoint,
                          prompt: Text("https://api.openai.com/v1"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationEndpoint) { _, _ in verifyResult = nil }
                SecureField("API 密钥", text: $translationAPIKey,
                            prompt: Text("sk-..."))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationAPIKey) { _, _ in verifyResult = nil }
                TextField("模型", text: $translationModel,
                          prompt: Text("gpt-4o-mini"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationModel) { _, _ in verifyResult = nil }
                Text("用于翻译和会议纪要。仅需 API 密钥。端点默认为 OpenAI，模型默认为 gpt-4o-mini。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        verifyConnection()
                    } label: {
                        if verifyInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("验证连接")
                        }
                    }
                    .disabled(verifyInFlight || translationAPIKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    switch verifyResult {
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(2)
                    case .none:
                        EmptyView()
                    }
                    Spacer()
                }
            }

            Section("会议纪要") {
                ForEach(minutesStore.prompts) { prompt in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.name)
                            Text(prompt.prompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            editingPrompt = prompt
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("编辑提示词")

                        Button {
                            promptPendingDelete = prompt
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(minutesStore.prompts.count == 1)
                        .help(minutesStore.prompts.count == 1
                              ? "无法删除最后一个提示词" : "删除提示词")
                    }
                }

                Button("添加提示词…") {
                    editingPrompt = MinutesPrompt(name: "", prompt: "")
                }

                HStack {
                    Text("模型上下文窗口")
                    Spacer()
                    TextField("16000", value: $minutesContextTokens, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                    Text("tokens")
                        .foregroundStyle(.secondary)
                }

                Text("提示词显示在转录内容上方的会议纪要菜单中。超过上下文窗口的转录内容会先分块摘要，然后合并为纪要。使用上方配置的 OpenAI API。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("语音识别模型") {
                ForEach(ModelCatalog.all) { model in
                    ModelRowView(model: model)
                }
                Text("选择已下载的模型用于转录。模型越小速度越快，但准确率越低。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("自定义模型") {
                HStack {
                    TextField("GGML 模型文件", text: $modelPath,
                              prompt: Text("自定义 ggml 模型路径"))
                        .textFieldStyle(.roundedBorder)
                    Button("浏览…") { browseModel() }
                }
                Text("仅在上方未选择模型时使用。否则请留空。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本地 API 服务器（兼容 OpenAI）") {
                Toggle("运行转录 API 服务器", isOn: $apiServerEnabled)
                    .onChange(of: apiServerEnabled) { _, on in
                        if on { apiServer.start() } else { apiServer.stop() }
                    }

                HStack {
                    Text("端口")
                    Spacer()
                    TextField("8080", value: $apiServerPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .disabled(apiServer.isRunning)
                }

                SecureField("API 密钥（可选）", text: $apiServerToken,
                            prompt: Text("留空以允许任何客户端"))
                    .textFieldStyle(.roundedBorder)

                Toggle("允许网络中其他设备访问", isOn: $apiServerAllowLAN)
                    .disabled(apiServer.isRunning)

                Toggle("详细请求日志（用于排查问题）", isOn: $apiServerVerboseLog)

                if apiServer.isRunning, let base = apiServer.baseURL {
                    HStack(spacing: 8) {
                        Label("运行中", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("\(base)/v1")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(base)/v1", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制基础 URL")
                        Spacer()
                    }
                } else if let err = apiServer.lastError {
                    Label(err, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                }

                Text("将任何兼容 OpenAI 的客户端指向上述地址（base_url）。端点：POST /v1/audio/transcriptions 和 /v1/audio/translations（multipart 格式，带 `file` 参数；response_format 支持 json、verbose_json、text、srt、vtt）。请求使用当前选择的模型。更改端口或网络设置后，需重新开关服务器才能生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("备份与恢复") {
                HStack(spacing: 10) {
                    Button("导出备份…") { exportBackup() }
                    Button("从备份恢复…") { pickRestoreFile() }
                    Spacer()
                }

                switch backupStatus {
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                case .none:
                    EmptyView()
                }

                Text("将你的设置（模型选择、翻译 API 配置、字体大小、最近使用的应用）保存到一个文件中。在新 Mac 上，将 Recordings 和 Transcriptions 文件夹复制到 ~/Library/Application Support/WhisperASR/ — 转录内容会从那里加载，音频链接会自动修复 — 然后在此处恢复设置。该文件包含你的翻译 API 密钥，请妥善保管。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear { ModelManager.shared.refresh() }
        .confirmationDialog(
            "从备份恢复？",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复") { performRestore() }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("这将用备份中的值覆盖当前设置（模型选择、翻译 API 配置、字体大小、最近使用的应用）。转录内容不受影响。")
        }
        .sheet(item: $editingPrompt) { prompt in
            MinutesPromptEditorSheet(prompt: prompt) { saved in
                minutesStore.upsert(saved)
            }
        }
        .confirmationDialog(
            "删除「\(promptPendingDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { promptPendingDelete != nil },
                set: { if !$0 { promptPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let prompt = promptPendingDelete {
                    minutesStore.delete(prompt)
                }
                promptPendingDelete = nil
            }
            Button("取消", role: .cancel) { promptPendingDelete = nil }
        } message: {
            Text("提示词文本将被删除。此操作无法撤销。")
        }
    }

    private func verifyConnection() {
        verifyInFlight = true
        verifyResult = nil
        let lang = targetLanguage.isEmpty ? "en" : targetLanguage
        Task {
            do {
                let translations = try await TranslationService.translateSegmentsWithOpenAI(
                    segmentTexts: ["Hello, world."],
                    targetLanguage: lang
                )
                await MainActor.run {
                    verifyInFlight = false
                    let sample = translations.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if sample.isEmpty {
                        verifyResult = .failure("Empty response")
                    } else {
                        verifyResult = .success("OK — \(sample)")
                    }
                }
            } catch {
                await MainActor.run {
                    verifyInFlight = false
                    verifyResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func browseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                modelPath = url.path
            }
        }
    }

    // MARK: - Backup & Restore

    private static func backupDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func exportBackup() {
        let backup = BackupService.makeBackup()
        guard let data = try? BackupService.encode(backup) else {
            backupStatus = .failure("Couldn't create backup data.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WhisperASR Backup \(Self.backupDateString()).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                backupStatus = .success("Settings exported.")
            } catch {
                backupStatus = .failure("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func pickRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                pendingRestore = try BackupService.decode(data)
                showRestoreConfirm = true
            } catch {
                backupStatus = .failure("Couldn't read backup: \(error.localizedDescription)")
            }
        }
    }

    private func performRestore() {
        guard let backup = pendingRestore else { return }
        BackupService.restore(backup)
        backupStatus = .success("Settings restored.")
        pendingRestore = nil
    }
}

// MARK: - Minutes Prompt Editor

private struct MinutesPromptEditorSheet: View {
    @State var prompt: MinutesPrompt
    let onSave: (MinutesPrompt) -> Void
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !prompt.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("会议纪要提示词")
                .font(.headline)

            TextField("名称（例如：每周站会、客户通话）", text: $prompt.name)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $prompt.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                .frame(minHeight: 220)

            Text("描述纪要的结构和重点。转录内容会自动附加，结果始终以 HTML 格式输出。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    onSave(prompt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }
}

// MARK: - Model Row

private struct ModelRowView: View {
    let model: WhisperModelInfo
    @State private var manager = ModelManager.shared
    @State private var confirmDelete = false

    private var downloader: ModelDownloader { manager.downloader(for: model) }
    private var isDownloaded: Bool { manager.isDownloaded(model) }
    private var isSelected: Bool { manager.selectedFileName == model.fileName }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                manager.selectedFileName = model.fileName
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)
            .help(isDownloaded ? "使用此模型进行转录" : "请先下载模型")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text("\(model.detail) · \(model.approxSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloaded {
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除已下载的模型")
            } else if downloader.state == .downloading {
                ProgressView(value: downloader.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    downloader.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("取消下载")
            } else {
                if case .failed = downloader.state {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("下载失败 — 点击下载重试")
                }
                Button(downloader.hasResumeData ? "继续" : "下载") {
                    downloader.startDownload()
                }
            }
        }
        .confirmationDialog(
            "删除 \(model.displayName)？",
            isPresented: $confirmDelete
        ) {
            Button("删除", role: .destructive) {
                manager.delete(model)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("模型文件（\(model.approxSizeText)）将从磁盘中移除。你可以稍后重新下载。")
        }
    }
}
