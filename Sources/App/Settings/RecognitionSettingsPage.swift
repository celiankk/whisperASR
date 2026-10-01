import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Network

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
                    Picker("", selection: $recognition.padSeconds) {
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
                // 未启用时给出「什么时候该开」的指引。这不是凑字数的说明：
                // 实测（端到端工作台）whisper 在 language=zh 下不区分简繁，
                // 默认会把普通话输出成繁体（"今天天氣很好"，CER 15.4%）；
                // 注入简体提示词后同一段音频降到 0.0%。用户不看这里就无从
                // 知道"繁体输出"是有开关可解的，会以为是模型能力问题。
                if !asrPrompt.enabled {
                    Text("开启后可用场景热词提升专业词汇（人名、产品名、术语）的识别准确率。"
                         + "中文简繁不需在此处理——简体脚本提示始终注入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        // 预览里包含**始终注入**的简体脚本提示（与开关无关，
                        // 见 ASRPromptManager.scriptHint）——文案要点明，
                        // 否则用户会以为自己只发出去自己填的那部分。
                        Text("实际注入：\(promptPreview)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text("注入 Online API 与本地 Whisper；Nemotron / Qwen 不受影响。"
                         + "「请用简体中文转写」一条始终注入（与开关无关），"
                         + "用于避免 Whisper 把普通话输出成繁体。")
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
    /// 下载源绑定配置中心（键 "modelDownloadSource" 不变）：直写 UserDefaults
    /// 会绕过配置中心，备份恢复与 reload 都刷不到这份 UI 状态。
    @State private var settings = ConfigurationManager.shared
    /// 引擎筛选（nil = 全部，按引擎分组显示；选定引擎只显示该引擎模型）。
    @State private var engineFilter: ModelEngine? = nil

    var body: some View {
        @Bindable var asr = settings.asr

        Section(header: IconSectionHeader("语音识别模型", icon: "square.stack.3d.down.right", color: .indigo)) {
            HStack {
                Text("下载源")
                Spacer()
                Picker("", selection: $asr.modelDownloadSource) {
                    Text("官方直连").tag("hf")
                    Text("国内镜像").tag("mirror")
                }
                .labelsHidden()
                .frame(width: 150)
                .pickerStyle(.menu)
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
