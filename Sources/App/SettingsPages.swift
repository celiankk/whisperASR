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
            Section("外观") {
                Picker("转录字体大小", selection: $general.transcriptFontSizeRaw) {
                    ForEach(TranscriptFontSize.allCases, id: \.rawValue) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("基础选项") {
                Toggle("录制后生成转录记录", isOn: $general.enableLiveTranscription)
                Text("关闭后录制结束不生成转录历史条目、不保留录音文件；实时字幕与翻译不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本地 API 服务器（兼容 OpenAI）") {
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
            Section("识别引擎") {
                // 三项选择：本地 / 在线 / Apple。
                // 本地涵盖 Whisper / Qwen / Nemotron（引擎按所选模型自动判定），
                // 语音识别模型 / 自定义模型 / 本地模型管理三区属于本地范畴。
                Picker("识别方式", selection: enginePickerSelection) {
                    Text("本地模型").tag(ASREngineSelection.auto)
                    Text("在线").tag(ASREngineSelection.online)
                    Text("Apple").tag(ASREngineSelection.apple)
                }
                .pickerStyle(.menu)
                Text(engineHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            case .funasr, .auto, .whisper, .qwen, .nemotron:
                ModelCatalogSection()
                CustomModelSection(recognition: recognition)
                LocalModelsSection()
            }

            Section("音频处理") {
                Picker("音频分片模式", selection: $recognition.audioChunkingMode) {
                    ForEach(AudioChunkingMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
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
                    Text("音频按最短识别时间聚合后发送；未达标时最长等待指定时间后强制发送，避免请求过于频繁。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(recognition.audioChunkingMode.appliesToText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("关闭：所有识别引擎保持原实时识别流程（每个音频块直接发送）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("ASR Prompt（热词提示）") {
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
                    Text("提示词注入 Online API 与本地 Whisper（initial_prompt）；Nemotron / Qwen 不受影响；关闭后行为与之前一致。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("识别语言") {
                // 按当前引擎显示：支持手动指定的（whisper / nemotron / 在线）
                // 显示语言选择器；Qwen 自动检测；Apple 按语言包设置。
                switch TranscriptionService.languageSupport {
                case .selectable:
                    Picker("识别语言", selection: $recognition.asrLanguage) {
                        Text("自动检测").tag("auto")
                        ForEach(TranscriptionService.availableLanguages(), id: \.code) { lang in
                            Text("\(lang.name)（\(lang.code)）").tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("指定语言可跳过语种检测，略微提升准确率与速度；不确定时保持自动检测。实时识别与文件转录同时生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    /// 引擎选择器（UI 三项）：本地 = 自动/Whisper/Qwen/Nemotron 归一显示
    /// （引擎按所选模型自动判定）；选中「本地」写回 auto，
    /// 旧的强制引擎值（whisper/qwen/nemotron）同样按本地显示与布局。
    private var enginePickerSelection: Binding<ASREngineSelection> {
        Binding(
            get: {
                switch settings.asr.asrEngine {
                case .online: return .online
                case .apple: return .apple
                case .auto, .whisper, .qwen, .nemotron, .funasr: return .auto
                }
            },
            set: { settings.asr.asrEngine = $0 }
        )
    }

    /// 引擎选择提示（按当前选择给出说明）。
    private var engineHint: String {
        switch settings.asr.asrEngine {
        case .online:
            return "在线：OpenAI 兼容 API（无需本地模型，识别数据发送到服务端）；需在下方启用并配置。"
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

    var body: some View {
        Section("语音识别模型") {
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
            // FunASR 分类组（实时推荐 / 中文实时 / 中文高精度 / 多语言）。
            HStack {
                Text("FunASR（阿里）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("SenseVoice 多语实时 · Paraformer 中文 · Nano 多语")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
            ForEach(ModelCatalog.all.filter { $0.engine == .funasr }) { model in
                ModelRowView(model: model)
            }
            Divider()
            HStack {
                Text("Whisper / Qwen3-ASR / Nemotron").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 2)
            ForEach(ModelCatalog.all.filter { $0.engine != .funasr }) { model in
                ModelRowView(model: model)
            }
            Text("选择已下载的模型用于转录。模型越小速度越快，但准确率越低。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 自定义模型路径区（本地引擎范畴，本地引擎选中时置顶显示）。
private struct CustomModelSection: View {
    @Bindable var recognition: ASRConfiguration

    var body: some View {
        Section("自定义模型") {
            HStack {
                TextField("GGML 模型文件", text: $recognition.customModelPath,
                          prompt: Text("自定义 ggml 模型路径"))
                    .textFieldStyle(.roundedBorder)
                Button("浏览…") { browse() }
            }
            Text("填写有效路径后优先使用该模型（支持按 GGUF 架构自动识别引擎）；留空则使用上方选择的模型。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        Section("本地模型管理") {
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
                ForEach(localModelManager.models) { model in
                    LocalModelRowView(model: model)
                }
            }
            Text("本地扫描不联网；在线下载与 LM Studio 探测仍由模型管理器负责。悬停模型行可直接启用（自定义路径优先级最高，同时只生效一个）。")
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
        Section("在线识别 API") {
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
                    Text("小米 MiMo：POST {base}/chat/completions（messages 内 input_audio），认证头 api-key:，asr_options.language 按上方选择（文档推荐显式指定提升准确率）。流式输出按文档 stream=true 逐 chunk 返回识别内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("完整端点 URL", text: $recognition.onlineASRBaseURL,
                              prompt: Text("https://your-server.com/asr/recognize"))
                        .textFieldStyle(.roundedBorder)
                    Text("Custom Endpoint：填写完整请求 URL，原样发送不做路径加工。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SecureField("API Key（本地兼容服务可留空）", text: $recognition.onlineASRApiKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Model Name", text: $recognition.onlineASRModel,
                          prompt: Text("whisper-1 / mini-V2.5-asr"))
                    .textFieldStyle(.roundedBorder)
                Text("OpenAI Compatible 音频转录（POST /audio/transcriptions，multipart form-data）；识别不使用 /chat/completions。")
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
                Text("在线识别失败不会导致 App 崩溃或影响本地识别；切换到其他引擎立即生效，无需重启。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("启用后可使用 OpenAI 兼容 Whisper API（如 OpenAI / Groq / 自建服务）进行识别。")
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

        Form {
            Section("翻译") {
                Picker("翻译方式", selection: $translation.mode) {
                    ForEach(TranslationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                switch mode {
                case .off:
                    Text("关闭实时字幕翻译。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .localModel:
                    Text("使用本机运行的 OpenAI 兼容服务（LM Studio / Ollama / llama.cpp）。地址留空时自动探测；模型名称留空时自动识别。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .onlineAPI:
                    Picker("目标语言", selection: $translation.targetLanguage) {
                        Text("关闭").tag("")
                        ForEach(TargetLanguage.available) { lang in
                            Text(lang.nativeName).tag(lang.id)
                        }
                    }
                    Text("音频 → 本地实时识别 → 原文字幕 → 在线 API 翻译 → 目标语言字幕。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .apple:
                    Picker("目标语言", selection: $translation.targetLanguage) {
                        Text("关闭").tag("")
                        ForEach(TargetLanguage.available) { lang in
                            Text(lang.nativeName).tag(lang.id)
                        }
                    }
                    Text("源语言自动检测。音频 → 本地实时识别 → 原文字幕 → Apple 翻译（TranslationSession）→ 目标语言字幕。需要 macOS 15+ 的系统翻译框架。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if mode == .localModel || mode == .onlineAPI {
                Section(mode == .localModel ? "本地模型配置" : "在线 API 配置") {
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

                    // 场景化预设：点选填入文本框（仍可手动改；「默认」清空自定义）。
                    HStack {
                        Text("提示词预设")
                        Spacer()
                        Menu {
                            ForEach(TranslationPromptPreset.all, id: \.name) { preset in
                                Button(preset.name) {
                                    translation.systemPrompt = preset.prompt
                                }
                            }
                        } label: {
                            Label("选择预设", systemImage: "text.badge.star")
                                .controlSize(.small)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    TextField("系统提示词（可选）", text: $translation.systemPrompt,
                              prompt: Text("你是专业字幕翻译助手。保持原意。不要解释。只输出翻译结果。"),
                              axis: .vertical)
                        .lineLimit(2...4)
                    Text("自定义 system message 提示词；留空使用默认翻译指令。编号输出格式要求会自动追加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                    Text("思考模型（DeepSeek-R1 / GLM / Qwen3 等）默认注入禁思考参数防止译文为空；自动按模型名识别。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("上下文句数")
                        Spacer()
                        Stepper("\(contextRounds) 句", value: contextRoundsBinding, in: 0...8)
                            .frame(width: 130)
                    }
                    Text("批量/实时翻译携带最近 N 句译文作上下文（保持术语一致）；0 = 关闭。")
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
                         ? "兼容 OpenAI 格式（/v1/chat/completions）。自动探测 127.0.0.1:1234（LM Studio）、11434（Ollama）、8080（llama.cpp/本应用 API 服务器）。"
                         : "兼容 OpenAI API 格式（/v1/chat/completions）。示例模型：Qwen3、GPT-5-mini、DeepSeek、Claude。翻译请求异步执行，失败自动重试，不阻塞字幕显示。")
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
    }

    private let themes: [SubtitleTheme] = [
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

    var body: some View {
        @Bindable var caption = settings.subtitle
        @Bindable var window = settings.window

        Form {
            Section("主题预设") {
                HStack(spacing: 8) {
                    ForEach(themes, id: \.name) { theme in
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
                        .help("\(theme.name)：字号\(Int(theme.sourceFontSize)) / 背景\(Int(theme.backgroundOpacity * 100))%")
                    }
                }
                Text("一键应用样式组合，应用后可继续手动微调下方各项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("字幕文字") {
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

            Section("字幕区域") {
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
                Text("字幕框填满浮窗内容区：拖动任意空白处移动窗口，左上角 40×40 区域缩放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("字幕编辑边框") {
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

            Section("字幕浮层行为") {
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
            Section("输入权限") {
                PermissionRow(
                    title: "屏幕捕获（系统音频）",
                    granted: screenCaptureMonitor.screenCaptureGranted,
                    hint: "系统设置 → 隐私与安全性 → 屏幕录制"
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

            Section("录制") {
                Toggle("默认包含麦克风", isOn: $audio.defaultIncludeMicrophone)
                Text("打开后，录制系统音频时默认同时收录麦克风；浮层内仍可临时切换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("当前输入状态") {
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
        .onAppear { screenCaptureMonitor.refresh() }
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
            Section("转录历史") {
                HStack {
                    Text("当前记录")
                    Spacer()
                    Text("\(appState.items.count) 条 · 上限 \(TranscriptionHistoryManager.maxItems) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("超出上限自动清理最旧记录；录制生成的音频在删除记录时移入废纸篓（可恢复），导入的原始文件保留。搜索与批量删除在历史侧栏内操作。")
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
                Text("转录内容实时自动保存，无需手动操作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Text("提示词显示在转录内容上方的会议纪要菜单中。超过上下文窗口的转录内容会先分块摘要，然后合并为纪要。使用「翻译」页配置的 OpenAI 兼容 API。")
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
            Section("服务状态") {
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

            Section("Online ASR") {
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

            Section("资源占用") {
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

            Section("最近日志") {
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

            Section("操作") {
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

            Section("权限") {
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

        Section("Apple Speech（系统语音识别）") {
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
            Text("已安装语言可直接离线使用；未安装语言不可选（需在系统设置下载语言包后进入本页刷新）。")
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
            Text("启用方式：识别 → 识别引擎 → Apple。授权在首次使用时请求（系统设置 → 隐私与安全性 → 语音识别）。")
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

            Section("Apple Translation（系统翻译）") {
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
                Text("状态由系统实际能力决定（Framework / 会话可创建性 / 语言资源），不依赖固定系统版本。启用方式：翻译 → 翻译方式 → Apple。")
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

struct TranslationPromptPreset {
    let name: String
    let prompt: String

    /// 内置预设（点选填入设置文本框，可继续手动修改；
    /// prompt 为空 = 清回默认指令）。
    static let all: [TranslationPromptPreset] = [
        .init(name: "默认（清空自定义）", prompt: ""),
        .init(name: "会议口语",
              prompt: "你是实时会议字幕翻译。用简洁自然的口语体翻译，保留说话人语气；专业术语首次出现时在括号内附原文。"),
        .init(name: "影视字幕",
              prompt: "你是影视字幕翻译。译文必须简短（不超过原文长度的 1.2 倍）以匹配字幕节奏；意译优先，人名地名用通行译名。"),
        .init(name: "技术文档",
              prompt: "你是技术文档翻译。术语精确（保留 API 名/命令/代码原文不译），语态正式，逻辑关系词严谨。"),
        .init(name: "身份核验",
              prompt: "You are translating for identity verification. Preserve all names, dates, ID numbers, and document field values EXACTLY as written. Never transliterate or reformat identifiers."),
    ]
}
