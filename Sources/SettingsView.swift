import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("transcriptFontSize") private var transcriptFontSize = TranscriptFontSize.normal.rawValue
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("targetLanguage") private var targetLanguage = ""
    @AppStorage("translationEndpoint") private var translationEndpoint = ""
    @AppStorage("translationAPIKey") private var translationAPIKey = ""
    @AppStorage("translationModel") private var translationModel = ""
    @AppStorage(TranslationService.ConfigKeys.timeout) private var translationTimeout = 30.0
    @AppStorage(TranslationService.ConfigKeys.maxContext) private var translationMaxContext = 16000
    @AppStorage(TranslationService.ConfigKeys.temperature) private var translationTemperature = 0.3
    /// 翻译方式统一由 AppState 管理（@Observable 单一数据源）；
    /// 这里只保留只读代理，写入一律走 appState.setTranslationMode。
    private var translationModeRaw: String { appState.translationMode.rawValue }

    // Local OpenAI-compatible API server
    @AppStorage(APIServer.enabledKey) private var apiServerEnabled = false
    @AppStorage(APIServer.portKey) private var apiServerPort = 8080
    @AppStorage(APIServer.tokenKey) private var apiServerToken = ""
    @AppStorage(APIServer.allowLANKey) private var apiServerAllowLAN = false
    @AppStorage(APIServer.verboseLogKey) private var apiServerVerboseLog = false
    @State private var apiServer = APIServer.shared
    @State private var localModelManager = LocalModelManager.shared
    @State private var screenCaptureMonitor = ScreenCaptureMonitor.shared
    @State private var asrStatus = "检测中…"
    @State private var asrStatusOK = false
    @State private var translationStatus = "检测中…"
    @State private var translationStatusOK = false

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

            Section("字幕文字") {
                HStack {
                    Text("原文字号")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleOverlaySourceFontSize },
                            set: { appState.setSubtitleOverlaySourceFontSize($0) }
                        ),
                        in: 20...72
                    )
                    .frame(width: 180)
                    Text("\(Int(appState.subtitleOverlaySourceFontSize))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                HStack {
                    Text("翻译字号")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleOverlayTranslationFontSize },
                            set: { appState.setSubtitleOverlayTranslationFontSize($0) }
                        ),
                        in: 20...72
                    )
                    .frame(width: 180)
                    Text("\(Int(appState.subtitleOverlayTranslationFontSize))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                Picker("字体粗细", selection: Binding(
                    get: { appState.subtitleFontWeight },
                    set: { appState.setSubtitleFontWeight($0) }
                )) {
                    Text("常规").tag("regular")
                    Text("中等").tag("medium")
                    Text("粗体").tag("bold")
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("行间距")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleLineSpacing },
                            set: { appState.setSubtitleLineSpacing($0) }
                        ),
                        in: 0...12
                    )
                    .frame(width: 180)
                    Text("\(Int(appState.subtitleLineSpacing))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                Picker("文字对齐", selection: Binding(
                    get: { appState.subtitleHorizontalAlignment },
                    set: { appState.setSubtitleHorizontalAlignment($0) }
                )) {
                    Text("左对齐").tag("left")
                    Text("居中").tag("center")
                }
                .pickerStyle(.segmented)
                Picker("字幕最大行数", selection: Binding(
                    get: { appState.maxSubtitleLines },
                    set: { appState.setMaxSubtitleLines($0) }
                )) {
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
                    Slider(
                        value: Binding(
                            get: { appState.subtitleContainerWidth },
                            set: { appState.setSubtitleContainerWidth($0) }
                        ),
                        in: 400...1200
                    )
                    .frame(width: 180)
                    Text("\(Int(appState.subtitleContainerWidth))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("字幕高度")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleContainerHeight },
                            set: { appState.setSubtitleContainerHeight($0) }
                        ),
                        in: 100...400
                    )
                    .frame(width: 180)
                    Text("\(Int(appState.subtitleContainerHeight))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleBackgroundOpacity },
                            set: { appState.setSubtitleBackgroundOpacity($0) }
                        ),
                        in: 0.1...0.8
                    )
                    .frame(width: 180)
                    Text("\(Int(appState.subtitleBackgroundOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("边框透明度")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleOverlayBorderOpacity },
                            set: { appState.setSubtitleOverlayBorderOpacity($0) }
                        ),
                        in: 0...0.3
                    )
                    .frame(width: 180)
                    Text("\(Int(appState.subtitleOverlayBorderOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Text("字幕框填满浮窗内容区：拖动任意空白处移动窗口，左上角 40×40 区域缩放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("字幕编辑边框") {
                Toggle("显示编辑边框", isOn: Binding(
                    get: { appState.subtitleEditBorderVisible },
                    set: { appState.setSubtitleEditBorderVisible($0) }
                ))
                HStack {
                    Text("边框颜色")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: {
                            SettingsView.color(fromHex: appState.subtitleEditBorderColorHex) ?? .white
                        },
                        set: { color in
                            appState.setSubtitleEditBorderColorHex(SettingsView.hex(from: color))
                        }
                    ))
                    .labelsHidden()
                }
                HStack {
                    Text("边框透明度")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleEditBorderOpacity },
                            set: { appState.setSubtitleEditBorderOpacity($0) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 180)
                    Text("\(Int(appState.subtitleEditBorderOpacity * 100))%")
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
                    TextField("3", value: Binding(
                        get: { appState.subtitleClearDelay },
                        set: { appState.setSubtitleClearDelay($0) }
                    ), format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                    Text("秒")
                        .foregroundStyle(.secondary)
                }
                Text("3 秒没有新的识别输入时自动清空浮窗字幕（1–10 秒）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("最短识别时长")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleMinSpeechDuration },
                            set: { appState.setSubtitleMinSpeechDuration($0) }
                        ),
                        in: 0.5...3,
                        step: 0.1
                    )
                    .frame(width: 180)
                    Text(String(format: "%.1fs", appState.subtitleMinSpeechDuration))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text("讲话不足该时长不显示字幕（避免嗯/啊等单字触发）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("最长单句时长")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleMaxSentenceDuration },
                            set: { appState.setSubtitleMaxSentenceDuration($0) }
                        ),
                        in: 2...15,
                        step: 0.5
                    )
                    .frame(width: 180)
                    Text(String(format: "%.1fs", appState.subtitleMaxSentenceDuration))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text("一句话超过该时长强制截断，内容移到下一句显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("停顿判定阈值")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { appState.subtitleSilencePause },
                            set: { appState.setSubtitleSilencePause($0) }
                        ),
                        in: 0.5...3,
                        step: 0.1
                    )
                    .frame(width: 180)
                    Text(String(format: "%.1fs", appState.subtitleSilencePause))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text("停顿超过该时长判定一句结束并发送翻译。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("5 秒未点击自动隐藏控件", isOn: Binding(
                    get: { appState.floatingOverlayAutoHide },
                    set: { appState.setFloatingOverlayAutoHide($0) }
                ))
                Button("浮层回到默认位置") {
                    appState.resetFloatingOverlayPosition()
                }
            }

            Section("翻译") {
                Picker("翻译方式", selection: Binding(
                    get: { appState.translationMode },
                    set: { appState.setTranslationMode($0) }
                )) {
                    ForEach(TranslationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                switch TranslationMode(rawValue: translationModeRaw) ?? .off {
                case .off:
                    Text("关闭实时字幕翻译。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .localModel:
                    Text("使用本机运行的 OpenAI 兼容服务（LM Studio / Ollama / llama.cpp）。地址留空时自动探测；模型名称留空时自动识别。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .onlineAPI:
                    Picker("目标语言", selection: $targetLanguage) {
                        Text("关闭").tag("")
                        ForEach(TargetLanguage.available) { lang in
                            Text(lang.nativeName).tag(lang.id)
                        }
                    }
                    Text("音频 → 本地实时识别 → 原文字幕 → 在线 API 翻译 → 目标语言字幕。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if TranslationMode(rawValue: translationModeRaw) ?? .off != .off {
                let mode = TranslationMode(rawValue: translationModeRaw) ?? .off
                Section(mode == .localModel ? "本地模型配置" : "在线 API 配置") {
                    TextField("API Base URL", text: $translationEndpoint,
                              prompt: Text(mode == .localModel ? "http://127.0.0.1:1234/v1" : "https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translationEndpoint) { _, _ in verifyResult = nil }
                    SecureField("API Key", text: $translationAPIKey,
                                prompt: Text(mode == .localModel ? "本地服务通常留空" : "sk-..."))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translationAPIKey) { _, _ in verifyResult = nil }
                    TextField("模型名称", text: $translationModel,
                              prompt: Text(mode == .localModel ? "留空自动检测" : "gpt-4o-mini"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: translationModel) { _, _ in verifyResult = nil }

                    HStack {
                        Text("请求超时时间")
                        Spacer()
                        TextField("30", value: $translationTimeout, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("最大上下文长度")
                        Spacer()
                        TextField("16000", value: $translationMaxContext, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .textFieldStyle(.roundedBorder)
                        Text("tokens")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("温度参数")
                        Slider(value: $translationTemperature, in: 0...2, step: 0.1)
                            .frame(width: 160)
                        Text(translationTemperature, format: .number.precision(.fractionLength(1)))
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

            Section("系统状态") {
                statusRow(
                    "屏幕捕获",
                    screenCaptureMonitor.screenCaptureGranted
                        ? "✓ 正常"
                        : "✗ 未授权（系统设置 → 隐私与安全性 → 屏幕录制）",
                    ok: screenCaptureMonitor.screenCaptureGranted
                )
                statusRow(
                    "麦克风",
                    screenCaptureMonitor.microphoneGranted
                        ? "✓ 正常"
                        : "✗ 未授权（系统设置 → 隐私与安全性 → 麦克风）",
                    ok: screenCaptureMonitor.microphoneGranted
                )
                statusRow("ASR", asrStatus, ok: asrStatusOK)
                statusRow("翻译", translationStatus, ok: translationStatusOK)
                Button("重新检测") { refreshSystemStatus() }
            }
            .onAppear {
                screenCaptureMonitor.refresh()
                refreshSystemStatus()
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
                    targetLanguage: lang,
                    local: TranslationMode(rawValue: translationModeRaw) ?? .off == .localModel
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

    /// 系统状态行：✓ 正常 / ✗ 异常原因。
    private func statusRow(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(ok ? .green : .red)
                .multilineTextAlignment(.trailing)
        }
    }

    /// 重新检测：屏幕捕获 / 麦克风 / ASR 模型 / 翻译服务。
    private func refreshSystemStatus() {
        screenCaptureMonitor.refresh()

        // ASR 状态与 TranscriptionService.resolveModelPath 同一优先级：
        // 自定义本地模型路径 > 显式选择的下载模型 > 自动（默认路径存在即可用）。
        let customPath = UserDefaults.standard.string(forKey: "modelPath") ?? ""
        if !customPath.isEmpty, FileManager.default.fileExists(atPath: customPath) {
            let name = (customPath as NSString).lastPathComponent
            asrStatus = "✓ 本地模型：\(name)"
            asrStatusOK = true
        } else {
            let modelName = ModelManager.shared.liveFileName.isEmpty
                ? ModelManager.shared.selectedFileName
                : ModelManager.shared.liveFileName
            if !modelName.isEmpty {
                asrStatus = "✓ \(modelName)"
                asrStatusOK = true
            } else if TranscriptionService.modelExists() {
                asrStatus = "✓ 自动（默认模型）"
                asrStatusOK = true
            } else {
                asrStatus = "✗ 未选择模型"
                asrStatusOK = false
            }
        }

        translationStatus = "检测中…"
        translationStatusOK = false
        let mode = TranslationMode(rawValue: translationModeRaw) ?? .off
        Task { @MainActor in
            if mode == .off {
                translationStatus = "关闭"
                translationStatusOK = true
            } else if mode == .localModel {
                let endpoint = await TranslationService.resolveLocalEndpoint()
                if let model = await TranslationService.fetchFirstLocalModel(baseURL: endpoint) {
                    translationStatus = "✓ \(model)（\(endpoint)）"
                    translationStatusOK = true
                } else {
                    translationStatus = "✗ 本地服务未连接（LM Studio / Ollama 未启动）"
                    translationStatusOK = false
                }
            } else if TranslationService.isAPIConfigured {
                translationStatus = "✓ 已配置"
                translationStatusOK = true
            } else {
                translationStatus = "✗ 未配置 API 端点 / Key"
                translationStatusOK = false
            }
        }
    }

    /// hex string → Color（ColorPicker 绑定）。
    static func color(fromHex hex: String) -> Color? {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Color → hex string（持久化）。
    static func hex(from color: Color) -> String {
        let nsColor = NSColor(color)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(
            format: "%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
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

// MARK: - Local Model Row

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
