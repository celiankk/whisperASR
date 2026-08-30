import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Network

// MARK: - 通用

struct GeneralSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var apiServer = APIServer.shared

    // Backup & restore
    @State private var backupStatus: BackupStatus? = nil
    @State private var pendingRestore: BackupService.BackupFile? = nil
    @State private var showRestoreConfirm = false

    private enum BackupStatus {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var general = settings.general

        Form {
            Section(header: IconSectionHeader("外观", icon: "paintbrush", color: .purple)) {
                Picker("转录字体大小", selection: $general.transcriptFontSizeRaw) {
                    ForEach(TranscriptFontSize.allCases, id: \.rawValue) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(header: IconSectionHeader("基础选项", icon: "switch.2", color: .gray)) {
                Toggle(isOn: $general.enableLiveTranscription) {
                    RowLabel(title: "录制后生成转录记录",
                             detail: "关闭后不生成历史条目、不保留录音；实时字幕与翻译不受影响")
                }
            }

            Section(header: IconSectionHeader("本地 API 服务器（兼容 OpenAI）", icon: "server.rack", color: .cyan)) {
                Toggle("运行转录 API 服务器", isOn: $general.apiServerEnabled)
                    .onChange(of: general.apiServerEnabled) { _, on in
                        if on { apiServer.start() } else { apiServer.stop() }
                    }

                HStack {
                    Text("端口")
                    Spacer()
                    TextField("8080", value: $general.apiServerPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .disabled(apiServer.isRunning)
                }

                SecureField("API 密钥（可选）", text: $general.apiServerToken,
                            prompt: Text("留空以允许任何客户端"))
                    .textFieldStyle(.roundedBorder)

                Toggle("允许网络中其他设备访问", isOn: $general.apiServerAllowLAN)
                    .disabled(apiServer.isRunning)

                Toggle("详细请求日志（用于排查问题）", isOn: $general.apiServerVerboseLog)

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

            Section(header: IconSectionHeader("备份与恢复", icon: "externaldrive.badge.timemachine", color: .teal)) {
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

                Text("导出全部设置到文件（含翻译 API 密钥，请妥善保管）；转录内容需另行复制文件夹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
    }

    // MARK: 备份与恢复

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
        settings.reload()
        backupStatus = .success("Settings restored.")
        pendingRestore = nil
    }
}

// MARK: - 识别

struct RecognitionSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var promptPreview = ""

    var body: some View {
        @Bindable var recognition = settings.asr
        @Bindable var asrPrompt = settings.asrPrompt

        Form {
            // 识别引擎置顶：选中哪个引擎（本地模型 / 在线 / Apple），
            // 对应的配置区紧跟其后显示；未选中的配置区按原顺序排在后面，
            // 内容不变。
            Section(header: IconSectionHeader("识别引擎", icon: "waveform.badge.mic", color: .blue)) {
                // 三项选择：本地 / 在线 / Apple。
                // 本地涵盖 Whisper / Qwen / Nemotron（引擎按所选模型自动判定），
                // 语音识别模型 / 自定义模型 / 本地模型管理三区属于本地范畴。
                Picker("识别方式", selection: enginePickerSelection) {
                    Text("本地模型").tag(ASREngineSelection.auto)
                    Text("在线").tag(ASREngineSelection.online)
                    Text("远程").tag(ASREngineSelection.remote)
                    Text("Apple").tag(ASREngineSelection.apple)
                }
                .pickerStyle(.menu)
                Text(engineHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 能力清单：统一能力描述层动态渲染（UI 不感知具体引擎）。
                HStack(alignment: .top, spacing: 8) {
                    Text("能力")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ASRCapabilitySummaryView(engine: currentCapabilityEngine)
                }
            }

            // 选中哪个方式，只显示该方式的配置区（严格互斥）：
            // - 本地模型：语音识别模型 / 自定义模型 / 本地模型管理（本地范畴三区）；
            // - 在线：在线识别 API；
            // - Apple：Apple Speech。
            // 通用设置（音频处理 / ASR Prompt / 识别语言）对所有方式生效，保持显示。
            switch recognition.asrEngine {
            case .apple:
                AppleSpeechSettingsSection()
            case .online:
                OnlineASRSection(recognition: recognition)
            case .remote:
                RemoteASRSettingsSection(recognition: recognition)
            case .funasr, .auto, .whisper, .qwen, .nemotron:
                ModelCatalogSection()
                CustomModelSection(recognition: recognition)
                LocalModelsSection()
            }

            Section(header: IconSectionHeader("音频处理", icon: "waveform.path.ecg", color: .red)) {
                Picker(selection: $recognition.audioChunkingMode) {
                    ForEach(AudioChunkingMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    RowLabel(title: "音频分片模式", detail: recognition.audioChunkingMode.appliesToText)
                }
                .pickerStyle(.menu)
                if recognition.audioChunkingMode != .off {
                    HStack {
                        Text("最短识别时间")
                        Spacer()
                        Stepper("\(Int(recognition.audioChunkingMinSeconds)) 秒",
                                value: $recognition.audioChunkingMinSeconds,
                                in: AudioChunkingConfig.minChunkRange, step: 1)
                    }
                    HStack {
                        Text("最长等待时间")
                        Spacer()
                        Stepper("\(Int(recognition.audioChunkingMaxWaitSeconds)) 秒",
                                value: $recognition.audioChunkingMaxWaitSeconds,
                                in: AudioChunkingConfig.maxWaitRange, step: 1)
                    }
                }

                HStack {
                    Text("输入补零")
                    Spacer()
                    Picker("", selection: padSecondsBinding) {
                        Text("禁用").tag(0.0)
                        Text("0.25s").tag(0.25)
                        Text("0.5s（默认）").tag(0.5)
                        Text("1s").tag(1.0)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .pickerStyle(.menu)
                }
                Text("推理输入对齐固定时长桶，稳定 GPU 推理形状；禁用则按原始长度发送。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Silero 神经网络 VAD（可选增强）：模型下载后自动启用。
                SileroVADDownloadRow()
            }

            Section(header: IconSectionHeader("ASR Prompt（热词提示）", icon: "text.badge.star", color: .orange)) {
                Toggle("启用识别提示词", isOn: $asrPrompt.enabled)
                if asrPrompt.enabled {
                    Picker("来源", selection: $asrPrompt.source) {
                        ForEach(ASRPromptSource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.menu)
                    if asrPrompt.source == .manual {
                        TextField("专业词汇 / 产品名 / 人名", text: $asrPrompt.customPrompt,
                                  prompt: Text("例如：Transformer、WhisperASR、张伟、Sprint 评审"),
                                  axis: .vertical)
                            .lineLimit(2...4)
                        Text("手动输入的内容将作为识别提示词注入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if asrPrompt.source == .scene {
                        Picker("场景模板", selection: $asrPrompt.sceneTemplate) {
                            ForEach(ASRSceneTemplate.allCases, id: \.self) { scene in
                                Text(scene.label).tag(scene)
                            }
                        }
                        Text("自动生成该场景的基础热词 Prompt。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if asrPrompt.source == .history {
                        Text("自动从最近 50 条历史字幕提取高频词与专有名词，无需手动维护。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if asrPrompt.source == .ai {
                        HStack {
                            Text("使用翻译服务配置的模型生成")
                            Spacer()
                            Button("重新生成") { ASRPromptManager.shared.regenerate() }
                        }
                        Text("仅在启动识别 / 切换场景 / 修改配置时生成，不会每句话调用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("附加关键词（逗号分隔）", text: $asrPrompt.keywords)
                    if !promptPreview.isEmpty {
                        Text("当前提示词：\(promptPreview)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text("注入 Online API 与本地 Whisper；Nemotron / Qwen 不受影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: IconSectionHeader("识别语言", icon: "globe", color: .blue)) {
                // 按当前引擎显示：支持手动指定的（whisper / nemotron / 在线）
                // 显示语言选择器；Qwen 自动检测；Apple 按语言包设置。
                // 显式读取建立 Observable 依赖：菜单栏改 asrLanguage 时
                // 本页 Picker 同步刷新（languageSupport 是 static 不参与追踪）。
                let _ = recognition.asrLanguage
                switch TranscriptionService.languageSupport {
                case .selectable:
                    Picker(selection: $recognition.asrLanguage) {
                        Text("自动检测").tag("auto")
                        ForEach(TranscriptionService.availableLanguages(), id: \.code) { lang in
                            Text("\(lang.name)（\(lang.code)）").tag(lang.code)
                        }
                    } label: {
                        RowLabel(title: "识别语言",
                                 detail: "可跳过语种检测提升速度；实时与文件转录同时生效")
                    }
                    .pickerStyle(.menu)
                case .autoOnly(let reason):
                    HStack {
                        Text("语言检测")
                        Spacer()
                        Text("自动检测")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .appleLocale:
                    HStack {
                        Text("识别语言")
                        Spacer()
                        Text("由 Apple Speech「当前语言」决定")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("在上方 Apple Speech 区选择语言（按系统已安装的语言包）；不支持自动检测。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ModelManager.shared.refresh()
            settings.reload()
            refreshPromptPreview()
        }
    }

    /// 刷新 ASR Prompt 预览（重新生成 + 快照显示）。
    private func refreshPromptPreview() {
        ASRPromptManager.shared.refresh()
        promptPreview = ASRPromptManager.shared.currentPrompt ?? ""
    }

    /// 输入补零时长（UserDefaults "asrPadSeconds"；nil = 默认 0.5）。
    private var padSecondsBinding: Binding<Double> {
        Binding(
            get: {
                UserDefaults.standard.object(forKey: "asrPadSeconds") == nil
                    ? 0.5 : UserDefaults.standard.double(forKey: "asrPadSeconds")
            },
            set: { UserDefaults.standard.set($0, forKey: "asrPadSeconds") }
        )
    }

    /// 引擎选择器（UI 三项）：本地 = 自动/Whisper/Qwen/Nemotron 归一显示
    /// （引擎按所选模型自动判定）；选中「本地」写回 auto，
    /// 旧的强制引擎值（whisper/qwen/nemotron）同样按本地显示与布局。
    private var enginePickerSelection: Binding<ASREngineSelection> {
        Binding(
            get: {
                switch settings.asr.asrEngine {
                case .online: return .online
                case .remote: return .remote
                case .apple: return .apple
                case .auto, .whisper, .qwen, .nemotron, .funasr: return .auto
                }
            },
            set: { settings.asr.asrEngine = $0 }
        )
    }

    /// 当前选择对应的能力查询引擎（ASREngineType）：
    /// 在线/远程/Apple/FunASR 直接映射；本地三项按模型路径自动判定
    /// （与 TranscriptionService.resolveEngine 同一事实源）。
    private var currentCapabilityEngine: ASREngineType {
        switch settings.asr.asrEngine {
        case .online: return .online
        case .remote: return .remote
        case .apple: return .apple
        case .funasr: return .funasr
        case .auto, .whisper, .qwen, .nemotron:
            return TranscriptionService.engineType(
                forModelPath: ModelPathResolver.resolveModelPath())
        }
    }

    /// 引擎选择提示（按当前选择给出说明）。
    private var engineHint: String {        switch settings.asr.asrEngine {
        case .online:
            return "在线：OpenAI 兼容 API（无需本地模型，识别数据发送到服务端）；需在下方启用并配置。"
        case .remote:
            return "远程：自托管端点（局域网 GPU 机器，OpenAI 兼容协议），本机无需下载模型；需在下方启用并配置。"
        case .apple:
            return "Apple：macOS 26 原生系统语音识别（需在系统设置中授权语音识别）。"
        case .funasr:
            return "FunASR：阿里 FunASR 模型（SenseVoice 多语实时 / Paraformer 中文 / Fun-ASR-Nano），全部本地运行。"
        case .auto, .whisper, .qwen, .nemotron:
            return "本地模型：按所选模型自动判定引擎（Whisper / Qwen / Nemotron / FunASR），全部本地运行，不联网。"
        }
    }
}

// MARK: - 识别页可重排配置区（选中引擎置顶显示）

/// 语音识别模型目录区（本地引擎选中时置顶显示）。
private struct ModelCatalogSection: View {
    /// 下载源（hf 直连 / 国内镜像）；下载 URL 域名按此重写。
    @State private var downloadSource = UserDefaults.standard.string(forKey: "modelDownloadSource") ?? "hf"
    /// 引擎筛选（nil = 全部，按引擎分组显示；选定引擎只显示该引擎模型）。
    @State private var engineFilter: ModelEngine? = nil

    var body: some View {
        Section(header: IconSectionHeader("语音识别模型", icon: "square.stack.3d.down.right", color: .indigo)) {
            HStack {
                Text("下载源")
                Spacer()
                Picker("", selection: $downloadSource) {
                    Text("官方直连").tag("hf")
                    Text("国内镜像").tag("mirror")
                }
                .labelsHidden()
                .frame(width: 150)
                .pickerStyle(.menu)
                .onChange(of: downloadSource) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "modelDownloadSource")
                }
            }
            Text("国内镜像（hf-mirror.com）适用于 Hugging Face 直连缓慢/失败的网络环境；下载中的任务不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
            // 引擎分类筛选：选定引擎只显示对应模型；全部时按引擎分组。
            HStack {
                Text(verbatim: "按引擎筛选")
                Spacer()
                Picker("", selection: $engineFilter) {
                    Text("全部").tag(ModelEngine?.none)
                    Text("Whisper").tag(ModelEngine?.some(.whisper))
                    Text("Qwen3").tag(ModelEngine?.some(.qwen3asr))
                    Text("Nemotron").tag(ModelEngine?.some(.nemotron))
                    Text("FunASR").tag(ModelEngine?.some(.funasr))
                }
                .labelsHidden()
                .frame(width: 130)
                .pickerStyle(.menu)
            }
            let groups: [(name: String, engine: ModelEngine)] = [
                ("FunASR（阿里）· SenseVoice 多语实时 · Paraformer 中文 · Nano 多语", .funasr),
                ("Whisper 模型", .whisper),
                ("Qwen3-ASR 模型", .qwen3asr),
                ("Nemotron 模型", .nemotron),
            ]
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if engineFilter == nil || engineFilter == group.engine {
                    if index > 0 && engineFilter == nil {
                        Divider()
                    }
                    HStack {
                        Text(group.name).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 2)
                    ForEach(ModelCatalog.all.filter { $0.engine == group.engine }) { model in
                        ModelRowView(model: model)
                    }
                }
            }
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 自定义模型路径区（本地引擎范畴，本地引擎选中时置顶显示）。
private struct CustomModelSection: View {
    @Bindable var recognition: ASRConfiguration
    /// 生效中模型路径（ModelPathResolver 同一判定：自定义 > 下载选择 > 默认）。
    @State private var effectivePath = ""

    var body: some View {
        Section(header: IconSectionHeader("自定义模型", icon: "folder.badge.gearshape", color: .indigo)) {
            HStack {
                TextField("GGML 模型文件", text: $recognition.customModelPath,
                          prompt: Text("自定义 ggml 模型路径"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: recognition.customModelPath) { _, _ in
                        refreshEffective()
                    }
                Button("浏览…") { browse() }
            }
            // 当前实际生效模型（三来源互斥后的结果，含来源标注）——
            // 自定义/下载列表/本地管理共写路径键，无此行用户无法分辨
            // 真正生效的是哪个。
            HStack(spacing: 4) {
                Image(systemName: effectiveIsCustom ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(effectiveIsCustom ? Color.green : Color.secondary)
                Text(effectiveText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("填写有效路径后优先使用该模型（支持按 GGUF 架构自动识别引擎）；留空则使用上方选择的模型。与「本地模型管理」「语音识别模型」三处启用互斥——启用任一处即清空其他来源。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { refreshEffective() }
    }

    private var effectiveIsCustom: Bool {
        !recognition.customModelPath.isEmpty
            && effectivePath == recognition.customModelPath
    }

    private var effectiveText: String {
        if effectivePath.isEmpty {
            return "当前生效：未找到有效模型"
        }
        let source = effectiveIsCustom
            ? "自定义路径生效中"
            : (effectivePath.contains(ModelCatalog.modelDirectory.path)
               ? "下载模型生效中" : "本地模型管理生效中")
        return "\(source)：\((effectivePath as NSString).lastPathComponent)"
    }

    private func refreshEffective() {
        effectivePath = ModelPathResolver.resolveModelPath()
        // resolveModelPath 回退到不存在的默认路径时视为无效。
        if !FileManager.default.fileExists(atPath: effectivePath) {
            effectivePath = ""
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                recognition.customModelPath = url.path
            }
        }
    }
}

/// 本地模型管理区（本地引擎范畴，本地引擎选中时置顶显示）。
private struct LocalModelsSection: View {
    @State private var localModelManager = LocalModelManager.shared

    var body: some View {
        Section(header: IconSectionHeader("本地模型管理", icon: "internaldrive", color: .indigo)) {
            HStack {
                TextField("模型目录", text: Binding(
                    get: { localModelManager.directoryPath },
                    set: { localModelManager.directoryPath = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Button("浏览…") { browse() }
                if !localModelManager.directoryPath.isEmpty {
                    Button("清空") { localModelManager.clearDirectory() }
                }
            }
            if localModelManager.models.isEmpty {
                Text(localModelManager.directoryPath.isEmpty
                     ? "选择包含 .gguf / .bin / .whisper 文件的目录后自动扫描。"
                     : "目录中未找到模型文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 按引擎分组显示（Whisper/Qwen3/FunASR/Nemotron 各组标题）。
                let grouped = Dictionary(grouping: localModelManager.models, by: \.engine)
                let order: [ModelEngine] = [.funasr, .qwen3asr, .nemotron, .whisper]
                ForEach(order, id: \.self) { engine in
                    if let models = grouped[engine], !models.isEmpty {
                        HStack {
                            Text(LocalModelInfo.engineGroupName(engine))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 2)
                        ForEach(models) { model in
                            LocalModelRowView(model: model)
                        }
                    }
                }
            }
            Text("本地扫描不联网；悬停模型行可直接启用，三处启用互斥。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                localModelManager.directoryPath = url.path
            }
        }
    }
}

/// 在线识别 API 配置区（Online 引擎选中时置顶显示）。
private struct OnlineASRSection: View {
    @Bindable var recognition: ASRConfiguration
    @State private var onlineASRTesting = false
    @State private var onlineASRResult: (success: Bool, message: String)?

    var body: some View {
        Section(header: IconSectionHeader("在线识别 API", icon: "icloud.and.arrow.down", color: .green)) {
            Toggle("启用在线识别", isOn: $recognition.onlineASREnabled)
            if recognition.onlineASREnabled {
                Picker("API 类型", selection: $recognition.onlineASRApiType) {
                    ForEach(OnlineASRApiType.allCases, id: \.self) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.menu)
                if recognition.onlineASRApiType == .openai {
                    TextField("Base URL", text: $recognition.onlineASRBaseURL,
                              prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                    Text("自动拼接 /audio/transcriptions；重复 /v1 自动去重。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if recognition.onlineASRApiType == .mimo {
                    TextField("Base URL", text: $recognition.onlineASRBaseURL,
                              prompt: Text("https://api.xiaomimimo.com/v1"))
                        .textFieldStyle(.roundedBorder)
                    Toggle("流式输出（stream）", isOn: $recognition.onlineASRStreaming)
                    HStack {
                        Text("指定语种")
                        Spacer()
                        Picker("", selection: $recognition.onlineASRMimoLanguage) {
                            Text("自动检测（auto）").tag("auto")
                            Text("中文（zh）").tag("zh")
                            Text("英文（en）").tag("en")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    Text("小米 MiMo：POST {base}/chat/completions，input_audio 多模态，认证头 api-key:。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("完整端点 URL", text: $recognition.onlineASRBaseURL,
                              prompt: Text("https://your-server.com/asr/recognize"))
                        .textFieldStyle(.roundedBorder)
                    Text("原样发送完整 URL，不做路径加工。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SecureField("API Key（本地兼容服务可留空）", text: $recognition.onlineASRApiKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Model Name", text: $recognition.onlineASRModel,
                          prompt: Text("whisper-1 / mini-V2.5-asr"))
                    .textFieldStyle(.roundedBorder)
                Text("POST /audio/transcriptions（multipart form-data）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        testConnection()
                    } label: {
                        if onlineASRTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(onlineASRTesting)
                    Spacer()
                    if let result = onlineASRResult {
                        Label(result.message,
                              systemImage: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(result.success ? Color.green : Color.red)
                            .lineLimit(2)
                    }
                }
                Text("失败不影响本地识别；切换引擎立即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func testConnection() {
        onlineASRTesting = true
        onlineASRResult = nil
        Task {
            let result = await OnlineASRService.testConnection()
            await MainActor.run {
                onlineASRTesting = false
                onlineASRResult = result
            }
        }
    }
}

/// 远程自托管 ASR 端点区（远程引擎选中时显示）：
/// 局域网 GPU 机器跑 OpenAI 兼容 /audio/transcriptions 服务
/// （whisper.cpp-server / faster-whisper-server 等），本机零模型。
private struct RemoteASRSettingsSection: View {
    @Bindable var recognition: ASRConfiguration
    @State private var testing = false
    @State private var testResult: (success: Bool, message: String)? = nil

    var body: some View {
        Section(header: IconSectionHeader("远程识别 API（自托管）", icon: "server.rack", color: .cyan)) {
            Toggle("启用远程识别", isOn: $recognition.remoteASREnabled)
            if recognition.remoteASREnabled {
                TextField("端点 Base URL",
                          text: $recognition.remoteASRBaseURL,
                          prompt: Text("http://192.168.1.100:8080/v1"))
                    .textFieldStyle(.roundedBorder)
                Text("自动拼接 /audio/transcriptions；重复 /v1 自动去重。示例服务：whisper.cpp-server、faster-whisper-server、Speaches。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("API 密钥（可选，自托管通常留空）",
                            text: $recognition.remoteASRApiKey)
                    .textFieldStyle(.roundedBorder)
                TextField("模型名（可选，仅多模型服务端需要）",
                          text: $recognition.remoteASRModel,
                          prompt: Text("whisper-1"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(testing ? "测试中…" : "测试连接") {
                        testConnection()
                    }
                    .disabled(testing || recognition.remoteASRBaseURL.isEmpty)
                    if let result = testResult {
                        Text(result.message)
                            .font(.caption)
                            .foregroundStyle(result.success ? .green : .red)
                            .lineLimit(2)
                    }
                }
            }
            Text("识别音频将发送到你所配置的服务器（请确保为可信网络）；端点不可达时该轮识别失败，不影响本地引擎。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        Task {
            // 复用在线连接测试（活动源切换后读远程键；测试期间临时激活）。
            RemoteASRConfig.activateAsActiveSource(true)
            defer { RemoteASRConfig.activateAsActiveSource(false) }
            let result = await OnlineASRService.testConnection()
            await MainActor.run {
                testing = false
                testResult = result
            }
        }
    }
}

// MARK: - 翻译

struct TranslationSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var verifyInFlight = false
    @State private var verifyResult: VerifyResult? = nil
    @State private var benchmarkInFlight = false
    @State private var benchmarkSummary: String?

    /// 思考模式控制（写入 UserDefaults "translationThinkingControl"）。
    private var thinkingControlBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "translationThinkingControl") ?? "auto" },
            set: { UserDefaults.standard.set($0, forKey: "translationThinkingControl") }
        )
    }

    /// 上下文句数（写入 UserDefaults "translationContextRounds"；nil = 默认 2）。
    private var contextRoundsBinding: Binding<Int> {
        Binding(
            get: {
                UserDefaults.standard.object(forKey: "translationContextRounds") == nil
                    ? 2 : UserDefaults.standard.integer(forKey: "translationContextRounds")
            },
            set: { UserDefaults.standard.set($0, forKey: "translationContextRounds") }
        )
    }

    private var contextRounds: Int { contextRoundsBinding.wrappedValue }

    private enum VerifyResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var translation = settings.translation
        let mode = translation.mode
        // 显式读取建立 Observable 依赖（菜单栏改 targetLanguage 时本页同步）。
        let _ = translation.targetLanguage

        Form {
            Section(header: IconSectionHeader("翻译", icon: "character.bubble", color: .orange)) {
                Picker(selection: $translation.mode) {
                    ForEach(TranslationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    RowLabel(title: "翻译方式",
                             detail: mode == .off ? "关闭实时字幕翻译"
                                 : mode == .localModel ? "LM Studio / Ollama / llama.cpp；地址与模型可自动探测"
                                 : mode == .onlineAPI ? "音频 → 实时识别 → 在线 API 翻译 → 目标语言字幕"
                                 : "音频 → 实时识别 → Apple 翻译 → 目标语言字幕（macOS 26+）")
                }

                if mode != .off {
                    Picker(selection: $translation.targetLanguage) {
                        Text("关闭").tag("")
                        ForEach(TargetLanguage.available) { lang in
                            Text(lang.nativeName).tag(lang.id)
                        }
                    } label: {
                        RowLabel(title: "目标语言")
                    }
                }
            }

            if mode == .localModel || mode == .onlineAPI {
                Section(header: IconSectionHeader(
                    mode == .localModel ? "本地模型配置" : "在线 API 配置",
                    icon: mode == .localModel ? "shippingbox" : "network",
                    color: mode == .localModel ? .indigo : .green)) {
                    TextField("API Base URL", text: $translation.endpoint,
                              prompt: Text(mode == .localModel ? "http://127.0.0.1:1234/v1" : "https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translation.endpoint) { _, _ in verifyResult = nil }
                    SecureField("API Key", text: $translation.apiKey,
                                prompt: Text(mode == .localModel ? "本地服务通常留空" : "sk-..."))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translation.apiKey) { _, _ in verifyResult = nil }
                    TextField("模型名称", text: $translation.model,
                              prompt: Text(mode == .localModel ? "留空自动检测" : "gpt-4o-mini"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translation.model) { _, _ in verifyResult = nil }

                    // 思考模型兼容：禁思考参数注入（DeepSeek-R1/GLM/Qwen3 等
                    // 思考模型会把译文写进 reasoning_content 导致翻译空）。
                    HStack {
                        Text("思考模式")
                        Spacer()
                        Picker("", selection: thinkingControlBinding) {
                            ForEach(TranslationService.ThinkingControl.allCases, id: \.rawValue) { control in
                                Text(control.label).tag(control.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .pickerStyle(.menu)
                    }
                    Text("DeepSeek-R1 / GLM / Qwen3 等思考模型自动禁思考，防止译文为空。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("上下文句数")
                        Spacer()
                        Stepper("\(contextRounds) 句", value: contextRoundsBinding, in: 0...8)
                            .frame(width: 130)
                    }
                    Text("携带最近 N 句译文保持术语一致；0 = 关闭。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("请求超时时间")
                        Spacer()
                        TextField("30", value: $translation.timeout, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("最大上下文长度")
                        Spacer()
                        TextField("16000", value: $translation.maxContext, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .textFieldStyle(.roundedBorder)
                        Text("tokens")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("温度参数")
                        Slider(value: $translation.temperature, in: 0...2, step: 0.1)
                            .frame(width: 160)
                        Text(translation.temperature, format: .number.precision(.fractionLength(1)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }

                    Text(mode == .localModel
                         ? "自动探测 1234（LM Studio）/ 11434（Ollama）/ 8080（llama.cpp）"
                         : "请求异步执行，失败自动重试，不阻塞字幕显示")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            verifyConnection()
                        } label: {
                            if verifyInFlight {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("检测 API 状态")
                            }
                        }
                        .disabled(
                            verifyInFlight
                                || (mode == .onlineAPI && !TranslationService.isAPIConfigured)
                        )

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

                    // 翻译基准：固定 3 句样本走当前配置（流式单句路径），
                    // 供本地/在线/各模型之间横向比较速度与输出质量。
                    HStack(spacing: 10) {
                        Button {
                            runBenchmark()
                        } label: {
                            if benchmarkInFlight {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("基准测试")
                            }
                        }
                        .disabled(benchmarkInFlight || verifyInFlight)
                        if let summary = benchmarkSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Spacer()
                    }
                }

                // 翻译提示词：独立区块（预设 + 模板编辑 + 变量插入 +
                // 恢复默认/保存；变量替换统一走 PromptBuilder）。
                // 仅 LLM 翻译（本地/在线）使用；Apple 翻译不经过提示词。
                if mode != .apple {
                    Section(header: IconSectionHeader("翻译提示词", icon: "text.quote", color: .orange)) {
                        TranslationPromptEditor(translation: translation)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 翻译基准：3 句样本（中英混合短/中/长句）串行走当前翻译配置，
    /// 输出总耗时 / 平均耗时 / 译文预览。失败显示错误。
    private func runBenchmark() {
        benchmarkInFlight = true
        benchmarkSummary = nil
        let samples = [
            "今天天气很好，我们出去走走吧。",
            "The quick brown fox jumps over the lazy dog near the river bank at dawn.",
            "会议纪要：项目进度已过半，测试阶段预计下周开始，请各团队准备好验收材料并及时同步风险。"
        ]
        let target = settings.translation.targetLanguage.isEmpty
            ? "en" : settings.translation.targetLanguage
        let local = settings.translation.mode == .localModel
        Task {
            var total: Double = 0
            var outputs: [String] = []
            var failure: String?
            for sample in samples {
                let start = Date()
                do {
                    let text = try await TranslationService.translateStreaming(
                        segmentText: sample, targetLanguage: target, local: local) { _ in }
                    total += Date().timeIntervalSince(start)
                    outputs.append(text)
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            await MainActor.run {
                benchmarkInFlight = false
                if let failure {
                    benchmarkSummary = "失败：\(failure)"
                } else {
                    let avg = total / Double(max(1, outputs.count))
                    benchmarkSummary = String(
                        format: "3 句共 %.1fs（平均 %.2fs/句）｜示例：%@",
                        total, avg, outputs.first.map { String($0.prefix(24)) } ?? "")
                }
            }
        }
    }

    private func verifyConnection() {
        verifyInFlight = true
        verifyResult = nil
        let lang = settings.translation.targetLanguage.isEmpty
            ? "en" : settings.translation.targetLanguage
        let local = settings.translation.mode == .localModel
        Task {
            do {
                let translations = try await TranslationService.translateSegmentsWithOpenAI(
                    segmentTexts: ["Hello, world."],
                    targetLanguage: lang,
                    local: local
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
}

// MARK: - 字幕

struct CaptionSettingsView: View {
    @State private var settings = ConfigurationManager.shared

    /// 字幕主题预设：一键应用字号/背景透明度/边框/字重组合，
    /// 应用后仍可手动微调（预设只写一次配置，不锁定）。
    private struct SubtitleTheme {
        let name: String
        let icon: String
        let sourceFontSize: Double
        let backgroundOpacity: Double
        let borderVisible: Bool
        let borderOpacity: Double
        let fontWeight: String
        /// 默认主题（值 = AppState 出厂缺省；与手调默认区分开便于恢复）。
        var isDefault = false
    }

    private let themes: [SubtitleTheme] = [
        .init(name: "默认", icon: "arrow.counterclockwise",
              sourceFontSize: 32, backgroundOpacity: 0.4,
              borderVisible: true, borderOpacity: 0.6, fontWeight: "medium",
              isDefault: true),
        .init(name: "观影", icon: "film",
              sourceFontSize: 30, backgroundOpacity: 0.55,
              borderVisible: false, borderOpacity: 0, fontWeight: "medium"),
        .init(name: "会议", icon: "person.2",
              sourceFontSize: 24, backgroundOpacity: 0.34,
              borderVisible: true, borderOpacity: 0.8, fontWeight: "semibold"),
        .init(name: "极简", icon: "textformat",
              sourceFontSize: 28, backgroundOpacity: 0.15,
              borderVisible: false, borderOpacity: 0, fontWeight: "medium"),
        .init(name: "大字", icon: "textformat.size.larger",
              sourceFontSize: 44, backgroundOpacity: 0.45,
              borderVisible: false, borderOpacity: 0, fontWeight: "bold"),
        .init(name: "高对比", icon: "circle.lefthalf.filled",
              sourceFontSize: 32, backgroundOpacity: 0.78,
              borderVisible: false, borderOpacity: 0, fontWeight: "bold"),
    ]

    /// 当前样式是否与某预设完全匹配；不匹配任何预设 = 自定义
    ///（手动微调任一项后自动落入此态）。
    private func matchedThemeIndex(subtitle: SubtitleConfiguration) -> Int? {
        let borderOpacity = subtitle.editBorderVisible ? subtitle.editBorderOpacity : 0
        return themes.firstIndex { theme in
            theme.sourceFontSize == subtitle.sourceFontSize
                && theme.backgroundOpacity == subtitle.backgroundOpacity
                && theme.borderOpacity == borderOpacity
                && theme.fontWeight == subtitle.fontWeight
        }
    }

    var body: some View {
        @Bindable var caption = settings.subtitle
        @Bindable var window = settings.window

        Form {
            Section(header: IconSectionHeader("主题预设", icon: "paintpalette", color: .purple)) {
                HStack(spacing: 8) {
                    ForEach(Array(themes.enumerated()), id: \.offset) { index, theme in
                        Button {
                            applyTheme(theme)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: theme.icon)
                                    .font(.system(size: 16))
                                Text(theme.name)
                                    .font(.system(size: 10))
                            }
                            .frame(width: 58, height: 48)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        // 当前匹配的预设高亮（accent 描边）；自定义态全部
                        // 恢复普通样式，由右侧徽标指示。
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(matchedThemeIndex(subtitle: caption) == index
                                        ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                        .help("\(theme.name)：字号\(Int(theme.sourceFontSize)) / 背景\(Int(theme.backgroundOpacity * 100))%")
                    }
                    // 自定义徽标：非预设组合时显示（手动微调自动落入）。
                    if matchedThemeIndex(subtitle: caption) == nil {
                        HStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16))
                            Text("自定义")
                                .font(.system(size: 10))
                        }
                        .frame(width: 58, height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.accentColor, lineWidth: 1.5)
                        )
                        .help("当前为手动微调的样式组合")
                    }
                }
                Text("一键应用样式组合，应用后可继续手动微调下方各项；微调后标记为自定义。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("字幕文字", icon: "textformat.size", color: .purple)) {
                HStack {
                    Text("原文字号")
                    Spacer()
                    Slider(value: $caption.sourceFontSize, in: 20...72)
                        .frame(width: 180)
                    Text("\(Int(caption.sourceFontSize))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                HStack {
                    Text("翻译字号")
                    Spacer()
                    Slider(value: $caption.translationFontSize, in: 20...72)
                        .frame(width: 180)
                    Text("\(Int(caption.translationFontSize))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                Picker("字体粗细", selection: $caption.fontWeight) {
                    Text("常规").tag("regular")
                    Text("中等").tag("medium")
                    Text("粗体").tag("bold")
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("行间距")
                    Spacer()
                    Slider(value: $caption.lineSpacing, in: 0...12)
                        .frame(width: 180)
                    Text("\(Int(caption.lineSpacing))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                Picker("文字对齐", selection: $caption.horizontalAlignment) {
                    Text("左对齐").tag("left")
                    Text("居中").tag("center")
                }
                .pickerStyle(.segmented)
                Picker("字幕最大行数", selection: $caption.maxLines) {
                    Text("1 行").tag(1)
                    Text("2 行").tag(2)
                    Text("3 行").tag(3)
                }
                Text("字号只影响字幕文字，不影响字幕框与窗口大小。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("字幕区域", icon: "rectangle.inset.filled", color: .purple)) {
                HStack {
                    Text("字幕宽度")
                    Spacer()
                    Slider(value: $caption.containerWidth, in: 400...1200)
                        .frame(width: 180)
                    Text("\(Int(caption.containerWidth))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("字幕高度")
                    Spacer()
                    Slider(value: $caption.containerHeight, in: 100...400)
                        .frame(width: 180)
                    Text("\(Int(caption.containerHeight))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Slider(value: $caption.backgroundOpacity, in: 0.1...0.8)
                        .frame(width: 180)
                    Text("\(Int(caption.backgroundOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("边框透明度")
                    Spacer()
                    Slider(value: $caption.borderOpacity, in: 0...0.3)
                        .frame(width: 180)
                    Text("\(Int(caption.borderOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Text("字幕框填满浮窗内容区：拖空白处移动窗口，拖边缘缩放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("字幕编辑边框", icon: "rectangle.dashed", color: .purple)) {
                Toggle("显示编辑边框", isOn: $caption.editBorderVisible)
                HStack {
                    Text("边框颜色")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: {
                            SettingsView.color(fromHex: caption.editBorderColorHex) ?? .white
                        },
                        set: { color in
                            caption.editBorderColorHex = SettingsView.hex(from: color)
                        }
                    ))
                    .labelsHidden()
                }
                HStack {
                    Text("边框透明度")
                    Spacer()
                    Slider(value: $caption.editBorderOpacity, in: 0...1)
                        .frame(width: 180)
                    Text("\(Int(caption.editBorderOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Text("只影响边框显示；关闭后窗口仍可移动与缩放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("字幕浮层行为", icon: "cursorarrow.click.2", color: .purple)) {
                HStack {
                    Text("字幕空闲清除")
                    Spacer()
                    TextField("3", value: $caption.clearDelay, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                    Text("秒")
                        .foregroundStyle(.secondary)
                }
                Text("3 秒没有新的识别输入时自动清空浮窗字幕（1–10 秒）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("5 秒未点击自动隐藏控件", isOn: $window.autoHideControls)
                Button("浮层回到默认位置") {
                    settings.subtitle.resetOverlayPosition()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 应用主题预设（写入配置，不锁定——应用后仍可微调）。
    private func applyTheme(_ theme: SubtitleTheme) {
        let subtitle = settings.subtitle
        subtitle.sourceFontSize = theme.sourceFontSize
        subtitle.backgroundOpacity = theme.backgroundOpacity
        subtitle.editBorderVisible = theme.borderVisible
        subtitle.editBorderOpacity = theme.borderOpacity
        subtitle.fontWeight = theme.fontWeight
    }
}

// MARK: - 音频

struct AudioSettingsView: View {
    @Environment(AudioRecorder.self) private var recorder
    @State private var settings = ConfigurationManager.shared
    @State private var screenCaptureMonitor = ScreenCaptureMonitor.shared

    var body: some View {
        @Bindable var audio = settings.audio

        Form {
            Section(header: IconSectionHeader("输入权限", icon: "mic.badge.xmark", color: .mint)) {
                // 屏幕捕获：始终显示拖拽式授权引导卡（状态徽标随授权
                // 变化）——引导入口常驻可见，拖拽体验不必先去系统设置
                // 移除授权才能看到。
                PermissionDragGuide(
                    permissionName: "屏幕录制",
                    settingsURL: URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!,
                    isGranted: screenCaptureMonitor.screenCaptureGranted,
                    onRecheck: { screenCaptureMonitor.requestAccess() }
                )
                PermissionRow(
                    title: "麦克风",
                    granted: screenCaptureMonitor.microphoneGranted,
                    hint: "系统设置 → 隐私与安全性 → 麦克风"
                )
                HStack {
                    Button("重新检测") { screenCaptureMonitor.refresh() }
                    Spacer()
                }
            }

            Section(header: IconSectionHeader("录制", icon: "record.circle", color: .red)) {
                Toggle(isOn: $audio.defaultIncludeMicrophone) {
                    RowLabel(title: "默认包含麦克风",
                             detail: "录制系统音频时默认同时收录；浮层内可临时切换")
                }
            }

            Section(header: IconSectionHeader("当前输入状态", icon: "waveform", color: .red)) {
                HStack {
                    Text("录制状态")
                    Spacer()
                    Text(recorderStateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("音频来源")
                    Spacer()
                    Text(recorder.includeMicrophone ? "系统音频 + 麦克风" : "系统音频")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let app = recorder.selectedApp {
                    HStack {
                        Text("录制应用")
                        Spacer()
                        Text(app.applicationName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            screenCaptureMonitor.refresh()
            // 进音频页时若未授权：主动请求一次（触发系统弹窗）。
            // 系统只弹一次，之后静默——引导卡的「打开系统设置」为兜底。
            if !screenCaptureMonitor.screenCaptureGranted {
                screenCaptureMonitor.requestAccess()
            }
        }
    }

    private var recorderStateText: String {
        switch recorder.state {
        case .idle: return "空闲"
        case .loading: return "加载中…"
        case .ready: return "就绪"
        case .recording: return "录制中（\(formattedDuration)）"
        case .saving: return "保存中…"
        case .permissionDenied: return "权限被拒绝"
        }
    }

    private var formattedDuration: String {
        let seconds = Int(recorder.recordingDuration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// 权限状态行：绿点正常 / 红点未授权 + 引导文字。
private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let hint: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if granted {
                Label("正常", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("未授权（\(hint)）", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - 记录

struct HistorySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var minutesStore = MinutesPromptStore.shared
    @AppStorage(MinutesPromptStore.contextTokensKey) private var minutesContextTokens = MinutesPromptStore.defaultContextTokens
    @State private var editingPrompt: MinutesPrompt? = nil
    @State private var promptPendingDelete: MinutesPrompt? = nil

    /// ~/Library/Application Support/WhisperASR/
    private static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperASR", isDirectory: true)
    }

    var body: some View {
        Form {
            Section(header: IconSectionHeader("转录历史", icon: "clock.arrow.circlepath", color: .teal)) {
                HStack {
                    Text("当前记录")
                    Spacer()
                    Text("\(appState.items.count) 条 · 上限 \(TranscriptionHistoryManager.maxItems) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("超出上限自动清理最旧；删除的录音移入废纸篓（可恢复）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("打开转录目录") {
                        NSWorkspace.shared.open(
                            Self.appSupportDirectory.appendingPathComponent("Transcriptions", isDirectory: true))
                    }
                    Button("打开录音目录") {
                        NSWorkspace.shared.open(
                            Self.appSupportDirectory.appendingPathComponent("Recordings", isDirectory: true))
                    }
                    Spacer()
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("会议纪要", icon: "doc.text.magnifyingglass", color: .pink)) {
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

                Text("长转录自动分块摘要后合并；使用「翻译」页配置的 API。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
}

// MARK: - 系统状态

/// 状态等级：绿正常 / 黄警告 / 红错误 / 灰未启用。
private enum StatusLevel {
    case ok, warning, error, idle

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .yellow
        case .error: return .red
        case .idle: return .secondary
        }
    }
}

struct SystemStatusSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioRecorder.self) private var recorder
    @State private var settings = ConfigurationManager.shared
    @State private var monitor = SystemMonitor()
    @State private var screenCaptureMonitor = ScreenCaptureMonitor.shared

    @State private var modelText = "检测中…"
    @State private var modelLevel: StatusLevel = .idle
    // 最近日志查看器（应用内排障入口，免手动挖 app.log）。
    @State private var logLines: [String] = []
    @State private var logFilter: LogCategory? = nil
    @State private var apiText = "检测中…"
    @State private var apiLevel: StatusLevel = .idle
    @State private var apiCheckInFlight = false
    @State private var onlineASRStats = OnlineASRStats.shared

    var body: some View {
        Form {
            Section(header: IconSectionHeader("服务状态", icon: "stethoscope", color: .green)) {
                StatusRow(title: "后端服务",
                          text: monitor.backendRunning ? "运行中" : "未启动",
                          level: monitor.backendRunning ? .ok : .idle)
                StatusRow(title: "识别模型", text: modelText, level: modelLevel)
                StatusRow(title: "网络状态",
                          text: monitor.networkOnline ? "正常" : "异常（无网络连接）",
                          level: monitor.networkOnline ? .ok : .error)
                StatusRow(title: "翻译 API", text: apiText, level: apiLevel)
                StatusRow(title: "当前识别", text: recognitionText, level: recognitionLevel)
                StatusRow(title: "音频分片",
                          text: AudioChunkingMode.current == .off
                              ? "关闭"
                              : AudioChunkingMode.current.label,
                          level: AudioChunkingMode.current == .off ? .idle : .ok)
            }

            Section(header: IconSectionHeader("Online ASR", icon: "dot.radiowaves.left.and.right", color: .green)) {
                StatusRow(title: "状态",
                          text: onlineASRStats.state == .error
                              ? "\(onlineASRStats.state.rawValue)：\(onlineASRStats.stateDetail)"
                              : onlineASRStats.state.rawValue,
                          level: onlineASRStats.state == .error ? .error
                              : (onlineASRStats.state == .running || onlineASRStats.state == .connecting ? .ok : .idle))
                HStack {
                    Text("总请求")
                    Spacer()
                    Text("\(onlineASRStats.totalRequests)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("成功 / 失败")
                    Spacer()
                    Text("\(onlineASRStats.successRequests) / \(onlineASRStats.failedRequests)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(onlineASRStats.failedRequests > 0 ? .red : .secondary)
                }
                HStack {
                    Text("平均响应时间")
                    Spacer()
                    Text(onlineASRStats.successRequests == 0
                         ? "—"
                         : String(format: "%.2f s", onlineASRStats.averageResponseTime))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if onlineASRStats.state == .error {
                    Text(onlineASRStats.stateDetail)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Section(header: IconSectionHeader("资源占用", icon: "memorychip", color: .green)) {
                HStack {
                    Text("CPU 占用")
                    Spacer()
                    ProgressView(value: min(1, max(0, monitor.cpuUsage)))
                        .progressViewStyle(.linear)
                        .tint(cpuLevel.color)
                        .frame(width: 140)
                    Text("\(Int(monitor.cpuUsage * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(cpuLevel.color)
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("内存占用")
                    Spacer()
                    Text(memoryText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(memoryLevel.color)
                }
                Text("每 2 秒自动刷新；CPU 为全机占用，内存为本应用常驻内存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("最近日志", icon: "doc.text.below.ecg", color: .gray)) {
                Picker("分类", selection: $logFilter) {
                    Text("全部").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.rawValue) { category in
                        Text(category.rawValue).tag(LogCategory?.some(category))
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: logFilter) { _, _ in refreshLogs() }
                ScrollView {
                    Text(logLines.isEmpty ? "暂无日志" : logLines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
                HStack {
                    Text("最近 \(logLines.count) 条（环形缓冲 1000 条）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { refreshLogs() }
                        .controlSize(.small)
                }
            }

            Section(header: IconSectionHeader("操作", icon: "wrench.and.screwdriver", color: .yellow)) {
                HStack(spacing: 10) {
                    Button {
                        reconnectTranslation()
                    } label: {
                        if apiCheckInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("重新连接翻译服务")
                        }
                    }
                    .disabled(apiCheckInFlight
                              || settings.translation.mode == .off
                              || (settings.translation.mode == .onlineAPI
                                  && !TranslationService.isAPIConfigured))

                    Button("重新加载模型") { reloadModel() }
                    Button("重新检测权限") { screenCaptureMonitor.refresh() }
                    Spacer()
                }
            }

            Section(header: IconSectionHeader("权限", icon: "lock.shield", color: .mint)) {
                StatusRow(title: "屏幕捕获",
                          text: screenCaptureMonitor.screenCaptureGranted ? "已授权" : "未授权",
                          level: screenCaptureMonitor.screenCaptureGranted ? .ok : .error)
                StatusRow(title: "麦克风",
                          text: screenCaptureMonitor.microphoneGranted ? "已授权" : "未授权",
                          level: screenCaptureMonitor.microphoneGranted ? .ok : .error)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshLogs() }
        .onAppear {
            monitor.start()
            screenCaptureMonitor.refresh()
            refreshModelStatus()
            checkTranslationStatus()
        }
        .onDisappear { monitor.stop() }
    }

    // MARK: 派生状态

    private var recognitionText: String {
        switch recorder.state {
        case .recording: return "录制中"
        case .saving: return "保存中…"
        case .loading: return "加载中…"
        case .permissionDenied: return "权限被拒绝"
        case .idle, .ready:
            return appState.isLiveTranscribing ? "实时转录中" : "空闲"
        }
    }

    private var recognitionLevel: StatusLevel {
        switch recorder.state {
        case .recording, .saving: return .ok
        case .loading: return .warning
        case .permissionDenied: return .error
        case .idle, .ready: return appState.isLiveTranscribing ? .ok : .idle
        }
    }

    private func refreshLogs() {
        logLines = Array(AppLogger.shared.recentLogs(category: logFilter).suffix(40))
    }

    private var cpuLevel: StatusLevel {
        monitor.cpuUsage > 0.9 ? .error : (monitor.cpuUsage > 0.7 ? .warning : .ok)
    }

    private var memoryText: String {
        let mb = Double(monitor.memoryBytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    private var memoryLevel: StatusLevel {
        let gb = Double(monitor.memoryBytes) / 1_073_741_824
        return gb > 4 ? .error : (gb > 2 ? .warning : .ok)
    }

    // MARK: 检测逻辑

    /// 模型状态：已加载（引擎报告）> 就绪（文件可用，按需加载）> 未选择模型。
    private func refreshModelStatus() {
        let engineModel = SubtitleEngine.shared.monitor.modelStatus
        if engineModel != "idle" {
            modelText = "已加载：\(engineModel)"
            modelLevel = .ok
            return
        }
        let customPath = settings.asr.customModelPath
        if !customPath.isEmpty, FileManager.default.fileExists(atPath: customPath) {
            modelText = "未加载（就绪：\((customPath as NSString).lastPathComponent)）"
            modelLevel = .warning
            return
        }
        let modelName = ModelManager.shared.liveFileName.isEmpty
            ? ModelManager.shared.selectedFileName
            : ModelManager.shared.liveFileName
        if !modelName.isEmpty {
            modelText = "未加载（就绪：\(modelName)）"
            modelLevel = .warning
        } else if TranscriptionService.modelExists() {
            modelText = "未加载（就绪：默认模型）"
            modelLevel = .warning
        } else {
            modelText = "未加载（未选择模型）"
            modelLevel = .error
        }
    }

    /// 翻译 API 状态：按当前翻译方式探测（不发送真实翻译请求）。
    private func checkTranslationStatus() {
        let mode = settings.translation.mode
        switch mode {
        case .off:
            apiText = "已关闭"
            apiLevel = .idle
        case .localModel:
            apiText = "检测中…"
            apiLevel = .idle
            Task { @MainActor in
                let endpoint = await TranslationService.resolveLocalEndpoint()
                if let model = await TranslationService.fetchFirstLocalModel(baseURL: endpoint) {
                    apiText = "连接成功：\(model)"
                    apiLevel = .ok
                } else {
                    apiText = "失败（本地服务未启动）"
                    apiLevel = .error
                }
            }
        case .onlineAPI:
            if TranslationService.isAPIConfigured {
                apiText = "已配置（点「重新连接」验证）"
                apiLevel = .warning
            } else {
                apiText = "失败（未配置 API 端点 / Key）"
                apiLevel = .error
            }
        case .apple:
            apiText = "检测中…"
            apiLevel = .idle
            Task { @MainActor in
                let status = AppleTranslationStatus.shared
                await status.refresh()
                switch status.state {
                case .available:
                    apiText = "可用（目标：\(status.targetLanguage)）"
                    apiLevel = .ok
                case .needResource:
                    apiText = "缺少语言资源（\(status.targetLanguage)）"
                    apiLevel = .warning
                case .unavailable:
                    apiText = "不可用（需要 macOS 26+）"
                    apiLevel = .error
                case .error:
                    apiText = "初始化失败"
                    apiLevel = .error
                case .idle, .initializing:
                    apiText = "检测中…"
                    apiLevel = .idle
                }
            }
        }
    }

    /// 重新连接：按当前翻译方式验证端到端连通。
    private func reconnectTranslation() {
        apiCheckInFlight = true
        let mode = settings.translation.mode
        let lang = settings.translation.targetLanguage.isEmpty
            ? "en" : settings.translation.targetLanguage
        let local = mode == .localModel
        Task {
            // Apple 翻译没有 HTTP 端点：走 Provider 的能力检测，
            // 不能像 local/online 一样发一条 OpenAI 翻译请求。
            if mode == .apple {
                let status = await TranslationManager.testConnection(for: .apple)
                await MainActor.run {
                    apiCheckInFlight = false
                    switch status {
                    case .connected:
                        let target = AppleTranslationStatus.shared.targetLanguage
                        apiText = target.isEmpty ? "可用" : "可用（目标：\(target)）"
                        apiLevel = .ok
                    case .notConfigured(let reason):
                        apiText = reason
                        apiLevel = .warning
                    case .failed(let reason):
                        apiText = "失败（\(reason)）"
                        apiLevel = .error
                    }
                }
                return
            }

            do {
                let translations = try await TranslationService.translateSegmentsWithOpenAI(
                    segmentTexts: ["Hello, world."],
                    targetLanguage: lang,
                    local: local
                )
                await MainActor.run {
                    apiCheckInFlight = false
                    let sample = translations.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if sample.isEmpty {
                        apiText = "失败（空响应）"
                        apiLevel = .error
                    } else {
                        apiText = "连接成功 — \(sample)"
                        apiLevel = .ok
                    }
                }
            } catch {
                await MainActor.run {
                    apiCheckInFlight = false
                    apiText = "失败（\(error.localizedDescription)）"
                    apiLevel = .error
                }
            }
        }
    }

    /// 重新加载模型：重扫下载目录与本地模型目录（不中断正在运行的识别）。
    private func reloadModel() {
        ModelManager.shared.refresh()
        LocalModelManager.shared.scan()
        settings.reload()
        refreshModelStatus()
        AppLogger.shared.log(.model, "Settings: model list reloaded from System Status page")
    }
}

// MARK: - Apple 服务

/// Apple Speech 配置区（独立可复用）：
/// - 识别页选中 Apple 引擎时置顶显示；
/// - Apple 服务页显示同一内容。
/// 进入视图自动刷新状态；授权未请求时自动请求（授权流程明确可见）。
struct AppleSpeechSettingsSection: View {
    @State private var settings = ConfigurationManager.shared
    @State private var speechStatus = AppleSpeechStatus.shared
    @State private var installedLocales: [String] = []
    @State private var uninstalledLocales: [String] = []
    @State private var uninstalledCount = 0
    @State private var engineStateText = "未启动"
    @State private var debugSummary = ""

    var body: some View {
        @Bindable var asr = settings.asr

        Section(header: IconSectionHeader("Apple Speech（系统语音识别）", icon: "apple.logo", color: .primary)) {
            StatusRow(title: "授权",
                      text: authText,
                      level: authLevel)
            StatusRow(title: "服务状态",
                      text: serviceStatusText,
                      level: serviceStatusLevel)
            StatusRow(title: "引擎状态",
                      text: engineStateText == "未启动" ? "未启动（录制时自动启动）" : engineStateText,
                      level: engineStateLevel)
            StatusRow(title: "麦克风权限",
                      text: micAuthText,
                      level: micAuthLevel)
            StatusRow(title: "语言资源",
                      text: speechStatus.installedLocaleCount == 0
                          ? "检测中…"
                          : "已安装 \(speechStatus.installedLocaleCount) 种 / 未安装 \(uninstalledCount) 种",
                      level: .ok)
            Picker("当前语言", selection: $asr.appleSpeechLocale) {
                // 已安装：可选。
                ForEach(installedLocales, id: \.self) { locale in
                    Text(localeDisplayName(locale)).tag(locale)
                }
                // 未安装：禁用展示（标注"未安装"）。
                ForEach(uninstalledLocales, id: \.self) { locale in
                    Text("\(localeDisplayName(locale))（未安装）")
                        .foregroundStyle(.secondary)
                        .tag(locale)
                }
            }
            .pickerStyle(.menu)
            Text("未安装语言需先在系统设置下载语言包。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("本地识别")
                Spacer()
                switch speechStatus.offlineState {
                case .available:
                    Label("本地可用（on-device）", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .needResource:
                    Label("需要下载资源", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                case .systemUnsupported:
                    Label("系统不支持", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .permissionDenied:
                    Label("权限被拒绝", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .notDetermined:
                    Label("未授权", systemImage: "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let reason = speechStatus.offlineReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("优先本地识别（on-device）", isOn: $asr.appleSpeechOnDevice)
            if speechStatus.speechAuth == .notDetermined {
                Button("请求语音识别授权") {
                    requestSpeechAuthorization()
                }
            }
            if speechStatus.speechAuth == .denied || speechStatus.speechAuth == .restricted
                || micAuthLevel == .error {
                Button("打开系统权限设置") {
                    AppleSpeechManager.openSystemPermissionSettings()
                }
            }
            Text("授权在首次使用时请求（系统设置 → 隐私与安全性 → 语音识别）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !debugSummary.isEmpty {
                Text("AppleSpeechDebug：\(debugSummary)")
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await speechStatus.refresh()
            await loadLocaleOptions()
            // 授权未请求时自动请求（进入页面即弹窗，授权流程明确可见）。
            if speechStatus.speechAuth == .notDetermined {
                _ = await AppleSpeechPermission.ensureSpeechAuthorized()
                await speechStatus.refresh()
            }
        }
        .onChange(of: asr.appleSpeechLocale) { _, _ in
            Task { await speechStatus.refresh() }
        }
    }

    // MARK: 派生状态

    private var serviceStatusText: String {
        switch speechStatus.speechAuth {
        case .notDetermined:
            return "未授权（点击「请求语音识别授权」）"
        case .denied:
            return "权限被拒绝（点击下方按钮跳转系统设置）"
        case .restricted:
            return "受限（系统限制）"
        case .authorized:
            return speechStatus.serviceAvailable ? "可用" : "语言不受支持"
        }
    }

    private var serviceStatusLevel: StatusLevel {
        switch speechStatus.speechAuth {
        case .notDetermined: return .warning
        case .denied, .restricted: return .error
        case .authorized: return speechStatus.serviceAvailable ? .ok : .error
        }
    }

    private func requestSpeechAuthorization() {
        Task {
            _ = await AppleSpeechPermission.ensureSpeechAuthorized()
            await speechStatus.refresh()
            await loadLocaleOptions()
        }
    }

    private var engineStateLevel: StatusLevel {
        switch engineStateText {
        case "Listening", "Processing", "Idle", "未启动": return .ok
        case "Unavailable", "Permission Denied", "Error": return .error
        default: return .warning
        }
    }

    private var micAuthText: String {
        switch AppleSpeechManager.microphoneAuthorizationStatus {
        case .authorized: return "已授权"
        case .denied: return "被拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未请求（录制时请求）"
        @unknown default: return "未知"
        }
    }

    private var micAuthLevel: StatusLevel {
        switch AppleSpeechManager.microphoneAuthorizationStatus {
        case .authorized: return .ok
        case .notDetermined: return .idle
        case .denied, .restricted: return .error
        @unknown default: return .idle
        }
    }

    private var authText: String {
        switch speechStatus.speechAuth {
        case .notDetermined: return "未请求（首次使用时请求）"
        case .authorized: return "已授权"
        case .denied: return "被拒绝"
        case .restricted: return "受限"
        }
    }

    private var authLevel: StatusLevel {
        switch speechStatus.speechAuth {
        case .authorized: return .ok
        case .notDetermined: return .idle
        case .denied, .restricted: return .error
        }
    }

    // MARK: 语言选项

    /// 语言选项：已安装（可选）+ 未安装（禁用）+ 引擎状态/调试摘要。
    private func loadLocaleOptions() async {
        let installed = await AppleLanguageManager.shared.installedLanguages()
        installedLocales = installed.map(\.identifier).sorted()
        let missing = await AppleLanguageManager.shared.unavailableLanguages()
        uninstalledLocales = missing.map(\.identifier).sorted()
        uninstalledCount = uninstalledLocales.count
        // 当前配置语言不在已安装中时附加（保证选择器有当前值，标注未安装）。
        let current = AppleSpeechManager.localeIdentifier
        if !installedLocales.contains(current), !uninstalledLocales.contains(current) {
            uninstalledLocales.append(current)
        }
        await refreshEngineStatus()
    }

    private func refreshEngineStatus() async {
        let manager = AppleSpeechManager.shared
        engineStateText = manager.engineStateDescription
        debugSummary = manager.debugStatsSummary
    }

    private func localeDisplayName(_ identifier: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return "\(name)（\(identifier)）"
    }
}

/// Apple 服务设置：Apple Speech（macOS 26 原生 SpeechAnalyzer / SpeechTranscriber）
/// + Apple Translation（TranslationSession）。
/// 状态由 AppleSpeechStatus / AppleTranslationStatus 统一检测（View 只读）；
/// 进入页面自动刷新；失败不影响其他 Provider。
struct AppleServicesSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var translationStatus = AppleTranslationStatus.shared

    var body: some View {
        Form {
            // Apple Speech 配置区复用识别页同一组件（选中 Apple 引擎时
            // 在识别页置顶显示）。
            AppleSpeechSettingsSection()

            Section(header: IconSectionHeader("Apple Translation（系统翻译）", icon: "apple.logo", color: .primary)) {
                StatusRow(title: "系统支持",
                          text: translationStatus.systemSupported ? "✓ 支持" : "✗ 不支持",
                          level: translationStatus.systemSupported ? .ok : .error)
                StatusRow(title: "Framework",
                          text: translationStatus.frameworkAvailable ? "✓ 可用" : "✗ 不可用",
                          level: translationStatus.frameworkAvailable ? .ok : .error)
                StatusRow(title: "翻译会话",
                          text: sessionText,
                          level: sessionLevel)
                StatusRow(title: "语言资源",
                          text: languageText,
                          level: languageLevel)
                StatusRow(title: "源语言",
                          text: "自动检测（中 / 英 / 日 / 韩 / 俄）",
                          level: .idle)
                StatusRow(title: "目标语言",
                          text: translationStatus.targetLanguage.isEmpty
                              ? "未配置（翻译页设置）" : translationStatus.targetLanguage,
                          level: .ok)
                StatusRow(title: "翻译方式",
                          text: "翻译页 → 翻译方式 → Apple",
                          level: .idle)
                StatusRow(title: "已安装语言",
                          text: translationStatus.installedLanguageCount == 0
                              ? "检测中…"
                              : "\(translationStatus.installedLanguageCount) 种",
                          level: .ok)
                Text("状态由系统实际能力决定；启用方式：翻译方式 → Apple。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            settings.reload()
            Task {
                await translationStatus.refresh()
                // 已安装语言数按需查（N+1 XPC，仅本页展示）。
                await translationStatus.refreshInstalledCount()
            }
        }
    }

    // MARK: 派生状态

    private var sessionText: String {
        switch translationStatus.state {
        case .available: return "✓ 可创建"
        case .needResource: return "需要语言资源"
        case .unavailable: return "✗ 不可用"
        case .error: return "初始化失败"
        case .idle, .initializing: return "检测中…"
        }
    }

    private var sessionLevel: StatusLevel {
        switch translationStatus.state {
        case .available: return .ok
        case .needResource: return .warning
        case .unavailable, .error: return .error
        case .idle, .initializing: return .idle
        }
    }

    private var languageText: String {
        switch translationStatus.languageStatus {
        case .installed: return "✓ 可用"
        case .supported: return "⚠ 缺少语言资源（需要下载语言包）"
        case .unsupported: return "✗ 不支持"
        case .unknown: return "检测中…"
        }
    }

    private var languageLevel: StatusLevel {
        switch translationStatus.languageStatus {
        case .installed: return .ok
        case .supported: return .warning
        case .unsupported: return .error
        case .unknown: return .idle
        }
    }
}

/// 状态指示灯行：● 标题 … 状态文字（绿/黄/红/灰）。

private struct StatusRow: View {
    let title: String
    let text: String
    let level: StatusLevel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(level.color)
                .frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(level.color)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

/// 引擎能力清单（统一能力描述层的设置页渲染）：
/// 数据来自 ASRCapabilityRegistry.capability(for:).summaryEntries，
/// 本视图不感知具体引擎（无 if engine == .xxx 分支）；新引擎只需
/// 在注册表补注册，UI 自动显示。
struct ASRCapabilitySummaryView: View {
    let engine: ASREngineType

    var body: some View {
        let entries = ASRCapabilityRegistry.shared.capability(for: engine).summaryEntries
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 5) {
                    Image(systemName: entry.supported ? "checkmark" : "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(entry.supported ? .green : .secondary)
                        .frame(width: 12)
                    Text(entry.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Silero 神经网络 VAD 下载行（可选增强，~2.2MB MIT）：
/// 未下载显示下载按钮；已下载显示状态（自动启用，无开关——判定链
/// 内部按可用性回落启发式，行为零风险）。
private struct SileroVADDownloadRow: View {
    @State private var downloaded = SherpaVAD.isModelDownloaded
    @State private var downloading = false
    @State private var statusText: String? = nil

    private static let modelSource = URL(string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!

    var body: some View {
        HStack {
            Text("神经网络人声检测")
            Spacer()
            if downloaded {
                Label("已启用", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if downloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("下载模型（2MB）") { download() }
                    .disabled(downloading)
            }
        }
        if let statusText {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("提升音乐底噪等非人声场景的静音判定准确率；未下载时行为不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func download() {
        downloading = true
        statusText = nil
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: Self.modelSource)
                let url = SherpaVAD.modelURL
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                await MainActor.run {
                    downloaded = SherpaVAD.isModelDownloaded
                    downloading = false
                    statusText = downloaded ? "模型就绪，下次录制自动生效。" : nil
                }
            } catch {
                await MainActor.run {
                    downloading = false
                    statusText = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 会议纪要提示词编辑

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

// MARK: - 本地模型行

/// 本地模型行：悬停显示「启用/停用」按钮。
/// 启用 = 写入 modelPath（自定义路径在 resolveModelPath 中优先级最高，立即生效）；
/// modelPath 是单值，天然保证同一时间只有一个模型在运行。
private struct LocalModelRowView: View {
    let model: LocalModelInfo
    @AppStorage("modelPath") private var modelPath = ""
    @State private var isHovering = false

    private var isActive: Bool { modelPath == model.path }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(model.sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isHovering {
                Button(isActive ? "停用" : "启用") {
                    if isActive {
                        modelPath = ""
                        AppLogger.shared.log(.model, "Local model disabled: \(model.path)")
                    } else {
                        modelPath = model.path
                        // 模型来源互斥：清下载列表选择（resolveModelPath 中
                        // modelPath 优先，保留会让列表「使用中」状态骗人）。
                        ModelManager.shared.selectedFileName = ""
                        AppLogger.shared.log(.model, "Local model enabled: \(model.path)")
                    }
                    ConfigurationManager.shared.reload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(isActive ? "使用中" : model.status)
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : .green)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - 模型行

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
                manager.select(model)
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
                // 千问同款启用按钮：开启（点击选用）/ 使用中（当前模型高亮）。
                Button {
                    manager.select(model)
                } label: {
                    Text(isSelected ? "使用中" : "开启")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(isSelected
                                ? Color.accentColor
                                : Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help(isSelected ? "当前转录模型" : "开启并使用此模型")
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
                    manager.cancelDownload(for: model)
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
                    manager.startDownload(for: model)
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


// MARK: - 翻译提示词预设（场景化风格库）

// TranslationPromptPreset 已迁移至 Pipeline/Translation/TranslationPromptPreset.swift
// （Pipeline 层——设置页与翻译运行时共用；变量化模板见 PromptBuilder）。

/// 翻译提示词编辑器（设置 → 翻译）：预设选择即时加载对应模板，
/// 编辑区修改后「保存」持久化（保存即视为自定义态）；「恢复默认」
/// 重载当前预设原始模板；变量点击追加到编辑区（不做复杂编辑器）。
private struct TranslationPromptEditor: View {
    @Bindable var translation: TranslationConfiguration
    /// 编辑缓冲（未保存的修改；保存时写回 translation.systemPrompt）。
    @State private var draft: String = ""
    /// 已加载到缓冲的来源（预设 id / customID），驱动恢复默认与描述显示。
    @State private var loadedID: String = ""
    @State private var saveConfirmation: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("翻译风格")
                Spacer()
                Picker("", selection: $loadedID) {
                    ForEach(TranslationPromptPreset.all, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    Text(TranslationPromptPreset.customID).tag(TranslationPromptPreset.customID)
                }
                .labelsHidden()
                .frame(width: 150)
                .pickerStyle(.menu)
                .onChange(of: loadedID) { _, newValue in
                    loadPreset(id: newValue)
                }
            }

            // 当前预设的场景描述（自定义态不显示）。
            if let preset = TranslationPromptPreset.with(id: loadedID) {
                Text("\(preset.name)：\(preset.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 110, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))

            // 变量说明（点击追加到编辑区末尾）。
            HStack(spacing: 10) {
                Text("可用变量：").font(.caption).foregroundStyle(.secondary)
                ForEach([("{source_lang}", "源语言"),
                         ("{target_lang}", "目标语言"),
                         ("{text}", "待翻译文本")], id: \.0) { variable, hint in
                    Button {
                        draft += variable
                    } label: {
                        Text("\(variable) \(hint)")
                            .font(.caption)
                            .monospaced()
                    }
                    .buttonStyle(.link)
                    .help("点击插入 \(variable)")
                }
            }

            HStack {
                Button("恢复默认") { restoreDefault() }
                    .disabled(TranslationPromptPreset.with(id: loadedID) == nil)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == translation.systemPrompt)
                if let saveConfirmation {
                    Text(saveConfirmation)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            Text("模板支持变量替换（发送前统一执行）；留空使用默认翻译指令。编号输出格式要求会自动追加，无需写入。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { loadPersisted() }
    }

    /// 当前缓冲内容对应的预设（与内置模板全等才算选中该预设）。
    private func matchedPreset() -> TranslationPromptPreset? {
        TranslationPromptPreset.all.first { $0.prompt == draft }
    }

    /// 启动时按持久化状态恢复（用户配置兼容）：
    /// - 已保存过 Prompt（systemPrompt 非空）→ 原样加载，不覆盖；
    /// - 首次安装（无任何配置）→ 加载默认预设「视频字幕」并落盘；
    /// - 持久化的预设 id 已不存在（预设被移除）→ 显示自定义态，内容保留。
    private func loadPersisted() {
        let savedID = translation.translationPromptPreset
        let savedPrompt = translation.systemPrompt
        if savedPrompt.isEmpty && savedID.isEmpty {
            // 首次安装：应用默认预设「视频字幕」。
            if let preset = TranslationPromptPreset.with(id: TranslationPromptPreset.defaultID) {
                draft = preset.prompt
                loadedID = preset.id
                translation.systemPrompt = preset.prompt
                translation.translationPromptPreset = preset.id
            }
            return
        }
        draft = savedPrompt
        // 保存内容与某内置模板全等 → 高亮该预设；否则自定义态。
        if let preset = matchedPreset() {
            loadedID = preset.id
        } else {
            loadedID = TranslationPromptPreset.customID
        }
        _ = savedID  // 旧 id 仅作参考；显示以内容匹配为准（预设改名/替换不破坏内容）
    }

    /// 切换预设：立即加载对应模板到编辑区（未保存，需点保存写入）。
    private func loadPreset(id: String) {
        guard let preset = TranslationPromptPreset.with(id: id) else { return }
        draft = preset.prompt
        saveConfirmation = nil
    }

    /// 恢复默认：重载当前预设的原始模板。
    private func restoreDefault() {
        guard let preset = TranslationPromptPreset.with(id: loadedID) else { return }
        draft = preset.prompt
    }

    /// 保存：写回配置（持久化）；与任何内置预设不同即标记自定义态。
    private func save() {
        translation.systemPrompt = draft
        if let preset = matchedPreset() {
            translation.translationPromptPreset = preset.id
        } else {
            translation.translationPromptPreset = TranslationPromptPreset.customID
        }
        saveConfirmation = "已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveConfirmation = nil }
    }
}
