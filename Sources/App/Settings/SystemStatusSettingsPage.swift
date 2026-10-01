import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Network

// MARK: - 系统状态

/// 状态等级：绿正常 / 黄警告 / 红错误 / 灰未启用。

struct SystemStatusSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioRecorder.self) private var recorder
    @State private var settings = ConfigurationManager.shared
    @State private var monitor = SystemMonitor.shared
    @State private var screenCaptureMonitor = ScreenCaptureMonitor.shared
    @State private var speechStatus = AppleSpeechStatus.shared

    /// 语音识别授权（Apple 引擎用）：权限集中在这里展示，不在引擎节复述。
    private var speechAuthText: String {
        switch speechStatus.speechAuth {
        case .authorized: return "已授权"
        case .denied: return "被拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未请求"
        }
    }

    private var speechAuthLevel: StatusLevel {
        switch speechStatus.speechAuth {
        case .authorized: return .ok
        case .denied, .restricted: return .error
        case .notDetermined: return .idle
        }
    }

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
                    SettingsHint(text: onlineASRStats.stateDetail, level: .error)
                }
            }

            Section(header: IconSectionHeader("延迟仪表盘", icon: "gauge.with.needle", color: .cyan)) {
                LatencyDashboardView()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                // 资源占用不再单列一节：仪表盘的 //CPU 与 //内存 卡片就是同一份数据，
                // 且刷新更快（1s vs 2s）。口径说明留在这里，一句话足够。
                SettingsHint(text: "端到端 / 翻译往返取最近样本；CPU 为全机占用，内存为本应用常驻，1 秒刷新。",
                             level: .idle)
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

            // 权限的唯一事实源：各引擎节/音频页不再各自复述一遍。
            Section(header: IconSectionHeader("权限", icon: "lock.shield", color: .mint)) {
                StatusRow(title: "屏幕录制",
                          text: screenCaptureMonitor.screenCaptureGranted ? "已授权" : "未授权",
                          level: screenCaptureMonitor.screenCaptureGranted ? .ok : .error)
                StatusRow(title: "麦克风",
                          text: screenCaptureMonitor.microphoneGranted ? "已授权" : "未授权",
                          level: screenCaptureMonitor.microphoneGranted ? .ok : .error)
                StatusRow(title: "语音识别",
                          text: speechAuthText,
                          level: speechAuthLevel)
            }
        }
        .formStyle(.grouped)
        // 单个 onAppear：此前是连续两个（refreshLogs 与状态初始化各一个），
        // 语义上同一次出现，合并后避免重复初始化路径。
        .onAppear {
            refreshLogs()
            monitor.start()
            screenCaptureMonitor.refresh()
            Task { await speechStatus.refresh() }
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
        case .failed: return "加载失败"
        case .idle, .ready:
            return appState.isLiveTranscribing ? "实时转录中" : "空闲"
        }
    }

    private var recognitionLevel: StatusLevel {
        switch recorder.state {
        case .recording, .saving: return .ok
        case .loading: return .warning
        case .permissionDenied, .failed: return .error
        case .idle, .ready: return appState.isLiveTranscribing ? .ok : .idle
        }
    }

    private func refreshLogs() {
        logLines = Array(AppLogger.shared.recentLogs(category: logFilter).suffix(40))
    }




    // MARK: 检测逻辑

    /// 模型状态：已加载（引擎报告）> 就绪（文件可用，按需加载）> 未选择模型。
    private func refreshModelStatus() {
        // 只描述「当前所选引擎」真正依赖的东西：Apple / 在线 / 远程引擎不加载
        // 本地 ggml 模型，按本地模型是否就绪报橙警会误导（选 Apple 时尤其明显）。
        switch settings.asr.asrEngine {
        case .apple:
            modelText = "Apple 引擎 · 无需本地模型"
            modelLevel = .ok
            return
        case .online:
            modelText = "在线 API · 不加载本地模型"
            modelLevel = .idle
            return
        case .remote:
            modelText = "自托管 · 不加载本地模型"
            modelLevel = .idle
            return
        case .auto, .whisper, .qwen, .nemotron, .funasr:
            break   // 本地引擎：继续走下面的模型就绪判定
        @unknown default:
            break
        }

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
        case .googleV1, .googleV2, .microsoft:
            // 公共免 key 通道：无端点/Key 可查，仅提示可验证连通性
            //（不在页面加载时就发请求，避免每次进状态页都撞限流）。
            apiText = "\(mode.label)（免 Key · 点「重新连接」验证）"
            apiLevel = .warning
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
                let sample: String
                if mode.isFreeWebChannel {
                    // 公共免 key 通道：无端点/Key，走 Provider 直接验证。
                    let result = try await TranslationManager.provider(for: mode).translate(
                        TranslationRequest(text: "Hello, world.", targetLanguage: lang))
                    sample = result.texts.first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                } else {
                    let translations = try await TranslationService.translateSegmentsWithOpenAI(
                        segmentTexts: ["Hello, world."],
                        targetLanguage: lang,
                        local: local
                    )
                    sample = translations.first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                await MainActor.run {
                    apiCheckInFlight = false
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
            // 简洁化：原「授权 / 服务状态 / 引擎状态 / 麦克风权限」四行是同一件事的
            // 复述（服务状态本身就是「授权 + 语言可解析」的派生，麦克风权限在
            // 系统状态 › 权限 集中页已有），压成一行状态摘要；引擎状态与 debug 串
            // 属于排障信息，收进默认折叠的「诊断」。
            StatusRow(title: "状态", text: speechSummary, level: speechSummaryLevel)
            StatusRow(title: "语言资源",
                      text: speechStatus.installedLocaleCount == 0
                          ? "检测中…"
                          : "已安装 \(speechStatus.installedLocaleCount) / \(speechStatus.installedLocaleCount + uninstalledCount) 种",
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

            // Apple 引擎走 SpeechAnalyzer，识别始终在本机完成（无云端回落到
            // 可关闭），此处只作事实说明，不提供无意义的开关。

            // 条件提示：正常态不占位，只在用户此刻需要动作时出现。
            if let hint = speechHint {
                SettingsHint(text: hint.hint, level: hint.level)
            }
            if speechStatus.speechAuth == .notDetermined {
                Button("请求语音识别授权") { requestSpeechAuthorization() }
            }
            if speechStatus.speechAuth == .denied || speechStatus.speechAuth == .restricted {
                Button("打开系统权限设置") {
                    AppleSpeechManager.openSystemPermissionSettings()
                }
            }

            DiagnosticsDisclosure(title: "诊断") {
                MonoDiagnostic(text: "引擎：\(engineStateText)")
                if !debugSummary.isEmpty {
                    MonoDiagnostic(text: debugSummary)
                }
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



    /// 一行状态摘要（吸收原「授权 / 服务状态 / 引擎状态」三行）。
    private var speechSummary: String {
        switch speechStatus.speechAuth {
        case .notDetermined: return "未授权"
        case .denied: return "权限被拒绝"
        case .restricted: return "系统受限"
        case .authorized:
            if !speechStatus.serviceAvailable { return "语言不受支持" }
            switch speechStatus.offlineState {
            case .available: return "就绪"
            case .needResource: return "需下载语言包"
            case .systemUnsupported: return "系统不支持"
            case .permissionDenied: return "权限被拒绝"
            case .notDetermined: return "检测中…"
            }
        @unknown default: return "未知"
        }
    }

    private var speechSummaryLevel: StatusLevel {
        switch speechSummary {
        case "就绪": return .ok
        case "未授权", "检测中…", "需下载语言包": return .warning
        default: return .error
        }
    }

    /// 需要时才出现的提示（正常态返回 nil → 整行不渲染）。
    private var speechHint: (hint: String, level: StatusLevel)? {
        switch speechStatus.speechAuth {
        case .notDetermined:
            return ("语音识别授权未请求，首次使用时会弹系统授权（系统设置 › 隐私与安全性 › 语音识别）。", .warning)
        case .denied, .restricted:
            return ("语音识别权限不可用，Apple 引擎无法识别；到系统设置打开后回来即可。", .error)
        case .authorized:
            if speechStatus.offlineState == .needResource {
                return ("当前语言包未安装，启动识别时会自动下载；也可先在系统设置里下好。", .warning)
            }
            if !uninstalledLocales.isEmpty {
                return ("其余 \(uninstalledLocales.count) 种语言未安装，需先在系统设置下载语言包。", .idle)
            }
            return nil
        @unknown default:
            return nil
        }
    }

    private func requestSpeechAuthorization() {
        Task {
            _ = await AppleSpeechPermission.ensureSpeechAuthorized()
            await speechStatus.refresh()
            await loadLocaleOptions()
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
        // 当前配置语言：先按规范键匹配已安装/未安装列表（配置里的 zh-CN 与
        // Apple 的 zh_CN 是同一种语言）。命中已安装时把规范 id 回写配置，
        // 让 Picker 的 tag 与 selection 对得上，并自愈历史遗留写法。
        let current = AppleSpeechManager.localeIdentifier
        if let match = installedLocales.first(where: {
            AppleLanguageManager.isSameLocale($0, current)
        }) {
            if match != current {
                settings.asr.appleSpeechLocale = match
            }
        } else if uninstalledLocales.contains(where: {
            AppleLanguageManager.isSameLocale($0, current)
        }) {
            // 已在未安装列表中（Apple 支持但未下载），不重复附加。
        } else {
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
struct SileroVADDownloadRow: View {
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
                StatusBadge("已启用", level: .ok)
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

// MARK: - 本地模型行

/// 本地模型行：悬停显示「启用/停用」按钮。
/// 启用 = 写入 modelPath（自定义路径在 resolveModelPath 中优先级最高，立即生效）；
/// modelPath 是单值，天然保证同一时间只有一个模型在运行。
struct LocalModelRowView: View {
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

struct ModelRowView: View {
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
                        .foregroundStyle(Palette.warn)
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


