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
                Toggle("启用实时转录", isOn: $general.enableLiveTranscription)
                Text("关闭后录制时不再生成实时字幕，仅保存录音。")
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
    @State private var localModelManager = LocalModelManager.shared
    @State private var onlineASRTesting = false
    @State private var onlineASRResult: (success: Bool, message: String)?
    @State private var promptPreview = ""

    var body: some View {
        @Bindable var recognition = settings.asr
        @Bindable var asrPrompt = settings.asrPrompt

        Form {
            Section("语音识别模型") {
                ForEach(ModelCatalog.all) { model in
                    ModelRowView(model: model)
                }
                Text("选择已下载的模型用于转录。模型越小速度越快，但准确率越低。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("识别引擎") {
                Picker("ASR Engine", selection: $recognition.asrEngine) {
                    ForEach(ASREngineSelection.allCases, id: \.self) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                Text(engineHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                            testOnlineASR()
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

            Section("自定义模型") {
                HStack {
                    TextField("GGML 模型文件", text: $recognition.customModelPath,
                              prompt: Text("自定义 ggml 模型路径"))
                        .textFieldStyle(.roundedBorder)
                    Button("浏览…") { browseModel() }
                }
                Text("填写有效路径后优先使用该模型（支持按 GGUF 架构自动识别引擎）；留空则使用上方选择的模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本地模型管理") {
                HStack {
                    TextField("模型目录", text: Binding(
                        get: { localModelManager.directoryPath },
                        set: { localModelManager.directoryPath = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("浏览…") { browseLocalModelDirectory() }
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

            Section("识别语言") {
                HStack {
                    Text("语言检测")
                    Spacer()
                    Text("自动识别（中文 / 英文等）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("识别语言由模型自动检测，无需手动指定；自适应静音阈值会按输入底噪自动校准断句。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// 引擎选择提示（按当前选择给出说明）。
    private var engineHint: String {
        switch settings.asr.asrEngine {
        case .auto:
            return "自动：按所选模型判定引擎（Whisper / Qwen / Nemotron），与 1.4 行为一致。"
        case .whisper:
            return "强制使用 whisper.cpp 引擎（本地 .bin 模型）。"
        case .qwen:
            return "强制使用 Qwen3-ASR 引擎（transcribe.cpp GGUF 模型）。"
        case .nemotron:
            return "强制使用 Nemotron 引擎（FluidAudio Core ML 模型包目录）。"
        case .online:
            return "使用在线 OpenAI 兼容 API，无需本地模型；需在上方启用并配置。"
        case .apple:
            return "使用系统 Apple Speech（需在系统设置中授权语音识别；默认关闭）。"
        }
    }

    private func testOnlineASR() {
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

    private func browseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.asr.customModelPath = url.path
            }
        }
    }

    private func browseLocalModelDirectory() {
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

// MARK: - 翻译

struct TranslationSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var verifyInFlight = false
    @State private var verifyResult: VerifyResult? = nil

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
                    Text("Apple 翻译需要 macOS 15+ 的系统翻译框架，当前系统版本暂不可用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if mode != .off {
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

                    TextField("系统提示词（可选）", text: $translation.systemPrompt,
                              prompt: Text("你是专业字幕翻译助手。保持原意。不要解释。只输出翻译结果。"),
                              axis: .vertical)
                        .lineLimit(2...4)
                    Text("自定义 system message 提示词；留空使用默认翻译指令。编号输出格式要求会自动追加。")
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
                }
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        @Bindable var caption = settings.subtitle
        @Bindable var window = settings.window

        Form {
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
    @State private var apiText = "检测中…"
    @State private var apiLevel: StatusLevel = .idle
    @State private var apiCheckInFlight = false
    @State private var onlineASRStats = OnlineASRStats.shared
    @State private var appleStatus = AppleServiceStatusManager.shared

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

            Section("Apple Services") {
                StatusRow(title: "Apple Speech",
                          text: appleSpeechStatusText,
                          level: appleSpeechStatusLevel)
                StatusRow(title: "Apple Translation",
                          text: appleTranslationStatusText,
                          level: appleTranslationStatusLevel)
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
        .onAppear {
            monitor.start()
            screenCaptureMonitor.refresh()
            refreshModelStatus()
            checkTranslationStatus()
            Task { await appleStatus.refresh() }
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

    private var appleSpeechStatusText: String {
        switch appleStatus.speechAuth {
        case .authorized: return appleStatus.speechServiceAvailable
            ? "可用（\(appleStatus.speechCurrentLocale)）" : "不可用"
        case .notDetermined: return "未请求授权"
        case .denied: return "被拒绝"
        case .restricted: return "受限"
        }
    }

    private var appleSpeechStatusLevel: StatusLevel {
        switch appleStatus.speechAuth {
        case .authorized: return appleStatus.speechServiceAvailable ? .ok : .error
        case .notDetermined: return .idle
        case .denied, .restricted: return .error
        }
    }

    private var appleTranslationStatusText: String {
        switch appleStatus.translationState {
        case .available: return "可用"
        case .needLanguageResource: return "缺少语言资源"
        case .unavailable: return "不可用"
        case .error: return "初始化失败"
        }
    }

    private var appleTranslationStatusLevel: StatusLevel {
        switch appleStatus.translationState {
        case .available: return .ok
        case .needLanguageResource: return .warning
        case .unavailable, .error: return .error
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
            apiText = "需要 macOS 15+"
            apiLevel = .warning
        }
    }

    /// 重新连接：发送一条真实翻译请求验证端到端连通。
    private func reconnectTranslation() {
        apiCheckInFlight = true
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

/// 状态指示灯行：● 标题 … 状态文字（绿/黄/红/灰）。
// MARK: - Apple 服务

/// Apple 服务设置：Apple Speech（系统语音识别）+ Apple Translation（系统翻译）。
/// 状态由 AppleServiceStatusManager 统一检测（View 不自行判断）；
/// 进入页面自动刷新；默认关闭；切换无需重启；失败不影响其他 Provider。
struct AppleServicesSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var appleStatus = AppleServiceStatusManager.shared
    @State private var localeOptions: [String] = []

    var body: some View {
        @Bindable var asr = settings.asr

        Form {
            Section("Apple Speech（系统语音识别）") {
                StatusRow(title: "授权",
                          text: authText,
                          level: authLevel)
                StatusRow(title: "服务状态",
                          text: appleStatus.speechServiceAvailable ? "可用" : "不可用",
                          level: appleStatus.speechServiceAvailable ? .ok : .error)
                StatusRow(title: "语言资源",
                          text: appleStatus.speechInstalledLocaleCount == 0
                              ? "检测中…"
                              : "本机可用语言：\(appleStatus.speechInstalledLocaleCount) 种",
                          level: .ok)
                HStack {
                    Text("当前语言")
                    Spacer()
                    Text("\(appleStatus.speechCurrentLocale)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if appleStatus.speechLocaleSupported {
                        Label("已安装", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("未安装", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Text("离线识别")
                    Spacer()
                    if appleStatus.speechOfflineAvailable {
                        Label("可用（on-device）", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("需要网络（服务器识别）")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                Picker("识别语言", selection: $asr.appleSpeechLocale) {
                    ForEach(localeOptions, id: \.self) { locale in
                        Text(localeDisplayName(locale)).tag(locale)
                    }
                }
                .pickerStyle(.menu)
                Text("列表只显示本机已安装的语音识别语言（可直接离线使用）；下载/删除语言包后进入本页自动刷新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("优先本地识别（on-device）", isOn: $asr.appleSpeechOnDevice)
                Text("启用方式：识别 → 识别引擎 → Apple。授权在首次使用时请求（系统设置 → 隐私与安全性 → 语音识别）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Translation（系统翻译）") {
                StatusRow(title: "系统支持",
                          text: appleStatus.translationSystemSupported ? "✓ 支持" : "✗ 不支持",
                          level: appleStatus.translationSystemSupported ? .ok : .error)
                StatusRow(title: "Framework",
                          text: appleStatus.translationFrameworkAvailable ? "✓ 可用" : "✗ 不可用",
                          level: appleStatus.translationFrameworkAvailable ? .ok : .error)
                StatusRow(title: "翻译会话",
                          text: sessionText,
                          level: sessionLevel)
                StatusRow(title: "语言资源",
                          text: languageText,
                          level: languageLevel)
                if !appleStatus.translationTargetLanguage.isEmpty {
                    Text("目标语言：\(appleStatus.translationTargetLanguage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StatusRow(title: "已安装语言",
                          text: appleStatus.translationInstalledLanguageCount == 0
                              ? "检测中…"
                              : "\(appleStatus.translationInstalledLanguageCount) 种",
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
                await appleStatus.refresh()
                await loadLocaleOptions()
            }
        }
        .onChange(of: asr.appleSpeechLocale) { _, _ in
            Task { await appleStatus.refresh() }
        }
    }

    // MARK: Speech 派生状态

    private var authText: String {
        switch appleStatus.speechAuth {
        case .notDetermined: return "未请求（首次使用时请求）"
        case .authorized: return "已授权"
        case .denied: return "被拒绝"
        case .restricted: return "受限"
        }
    }

    private var authLevel: StatusLevel {
        switch appleStatus.speechAuth {
        case .authorized: return .ok
        case .notDetermined: return .idle
        case .denied, .restricted: return .error
        }
    }

    // MARK: Translation 派生状态

    private var sessionText: String {
        switch appleStatus.translationState {
        case .available: return "✓ 可创建"
        case .needLanguageResource: return "需要语言资源"
        case .unavailable: return "✗ 不可用"
        case .error: return "初始化失败"
        }
    }

    private var sessionLevel: StatusLevel {
        switch appleStatus.translationState {
        case .available: return .ok
        case .needLanguageResource: return .warning
        case .unavailable, .error: return .error
        }
    }

    private var languageText: String {
        if appleStatus.translationLanguageAvailable {
            return "✓ 可用"
        }
        return appleStatus.translationLanguageNeedsDownload
            ? "⚠ 缺少语言资源（需要下载语言包）"
            : "✗ 不支持"
    }

    private var languageLevel: StatusLevel {
        if appleStatus.translationLanguageAvailable { return .ok }
        return appleStatus.translationLanguageNeedsDownload ? .warning : .error
    }

    // MARK: 语言选项

    /// 语言选项：只显示本机已安装语言（可直接离线使用）；
    /// 当前配置语言未安装时附加显示（保证选择器有当前值）。
    private func loadLocaleOptions() async {
        var options = await AppleSpeechLanguageManager.shared.installedLanguages()
            .map(\.identifier)
        let current = AppleSpeechProvider.localeIdentifier
        if !options.contains(current) {
            options.append(current)
        }
        localeOptions = options.sorted()
    }

    private func localeDisplayName(_ identifier: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return "\(name)（\(identifier)）"
    }
}

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
