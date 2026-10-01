import Foundation
import Observation

// MARK: - 配置中心（ConfigurationManager）
//
// 统一管理所有设置（AppState 拆分后的配置架构）：
//
//   AppConfiguration
//   ├── ASRConfiguration         识别引擎 / 模型路径 / 在线识别 / 音频分片
//   ├── TranslationConfiguration 翻译方式 / 端点 / 密钥 / 模型 / 上下文
//   ├── SubtitleConfiguration    字幕样式（代理 AppState 联动浮层）
//   ├── AudioConfiguration       录音（麦克风默认等）
//   ├── WindowConfiguration      浮层窗口偏好
//   └── ASRPromptConfiguration   会议纪要提示词（MinutesPromptStore）
//
// 规则：
// - 设置页面只绑定 ConfigurationManager（不直接修改业务对象 / UserDefaults）；
// - 业务模块只读取配置（UserDefaults 键与 1.4 完全一致，旧配置兼容）；
// - 支持保存（didSet 持久化）/ 读取 / 默认值兜底 / 版本迁移（ConfigurationSchema）。
//
// 取代 1.4 的 SettingsManager；字幕/翻译等需要联动浮层状态机的写入
// 经 AppState setter 转发（attach(appState:) 注入）。

/// 配置 schema 版本迁移（UserDefaults "configSchemaVersion"）。
/// 旧配置（无版本键）视为 v0；v0 → v1 键与 1.4 完全一致，无需数据搬运，
/// 仅写入版本号。未来版本在此追加迁移分支。
enum ConfigurationSchema {
    static let currentVersion = 1
    static let versionKey = "configSchemaVersion"

    /// 启动 / reload 时调用：低于当前版本则执行迁移并写入新版本号。
    static func migrateIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: versionKey)
        guard stored < currentVersion else { return }
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }
}

// MARK: - 通用（API 服务器 / 转录字体）

@Observable
final class GeneralSettings {
    /// APIServer.*Key 的镜像（APIServer 是 @MainActor，这里非隔离上下文不能直接引用；
    /// 值必须与 APIServer.swift 中的键保持一致）。
    private enum APIKeys {
        static let enabled = "apiServerEnabled"
        static let port = "apiServerPort"
        static let token = "apiServerToken"
        static let allowLAN = "apiServerAllowLAN"
        static let verboseLog = "apiServerVerboseLogging"
        static let defaultPort = 8080
    }

    @ObservationIgnored weak var appState: AppState?

    var transcriptFontSizeRaw: String = TranscriptFontSize.normal.rawValue {
        didSet { UserDefaults.standard.set(transcriptFontSizeRaw, forKey: "transcriptFontSize") }
    }

    /// 实时转录开关（AppState 持有，浮层读取；这里只做代理绑定）。
    var enableLiveTranscription: Bool {
        get { appState?.enableLiveTranscription ?? true }
        set { appState?.enableLiveTranscription = newValue }
    }

    // 本地 API 服务器（键镜像 APIServer.*Key，启动/停止由页面调 APIServer.shared）。
    var apiServerEnabled = false {
        didSet { UserDefaults.standard.set(apiServerEnabled, forKey: APIKeys.enabled) }
    }

    /// 从 UserDefaults 回读开关状态（保持内存值与磁盘一致）。
    ///
    /// APIServer.markStopped 在启动失败时会把 apiServerEnabled 写回 false——
    /// 那是**外部写入**，@Observable 观察不到，内存值会停在 true，于是
    /// 「开关显示开、实际已停」一直漂移到下次 reload。设置页在出现时、
    /// 以及服务器运行状态变化时调用本方法纠正。
    func refreshApiServerEnabled() {
        let stored = UserDefaults.standard.bool(forKey: APIKeys.enabled)
        if apiServerEnabled != stored { apiServerEnabled = stored }
    }
    var apiServerPort = 8080 {
        didSet { UserDefaults.standard.set(apiServerPort, forKey: APIKeys.port) }
    }
    var apiServerToken = "" {
        didSet { UserDefaults.standard.set(apiServerToken, forKey: APIKeys.token) }
    }
    var apiServerAllowLAN = false {
        didSet { UserDefaults.standard.set(apiServerAllowLAN, forKey: APIKeys.allowLAN) }
    }
    var apiServerVerboseLog = false {
        didSet { UserDefaults.standard.set(apiServerVerboseLog, forKey: APIKeys.verboseLog) }
    }

    /// 端口合法区间（设置页校验用）。1-65535 是系统合法范围，但 <1024 需
    /// root 权限、普通用户绑定必然失败并让 APIServer 静默回落 8080 —— 于是
    /// 「UI 显示端口」与「实际监听端口」不一致。故 UI 只接受 1024-65535。
    static let apiServerPortRange = 1024...65535

    init() { reload() }

    func reload() {
        let defaults = UserDefaults.standard
        transcriptFontSizeRaw = defaults.string(forKey: "transcriptFontSize")
            ?? TranscriptFontSize.normal.rawValue
        // 开关：reload 时把外部写入（APIServer.markStopped 失败回落）拉回内存。
        refreshApiServerEnabled()
        let port = defaults.integer(forKey: APIKeys.port)
        apiServerPort = port == 0 ? APIKeys.defaultPort : port
        apiServerToken = defaults.string(forKey: APIKeys.token) ?? ""
        apiServerAllowLAN = defaults.bool(forKey: APIKeys.allowLAN)
        apiServerVerboseLog = defaults.bool(forKey: APIKeys.verboseLog)
    }
}

// MARK: - ASR 配置

/// 识别引擎选择（UserDefaults "asrEngine"）：
/// - auto：按所选模型自动判定引擎（1.4 默认行为，推荐）；
/// - whisper / qwen / nemotron：强制使用对应本地引擎；
/// - online：使用在线 OpenAI 兼容 API（需在设置中启用并配置）；
/// - remote：远程自托管端点（局域网 GPU 机器，OpenAI 兼容协议，密钥可选）；
/// - apple：使用 macOS 26 原生 Apple Speech（SpeechAnalyzer / SpeechTranscriber）。
/// 切换立即生效，无需重启；实时转录与文件转录同时切换。
enum ASREngineSelection: String, CaseIterable, Codable {
    case auto
    case whisper
    case qwen
    case nemotron
    case online
    case remote
    case apple
    case funasr

    static let key = "asrEngine"

    /// 当前保存的引擎选择。
    static var current: ASREngineSelection {
        ASREngineSelection(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }
}

/// 在线 ASR API 类型（UserDefaults "onlineASRApiType"）：
/// - openai：OpenAI Compatible（baseURL 如 https://xxx/v1，自动拼 /audio/transcriptions）；
/// - mimo：小米 MiMo（POST {base}/chat/completions，messages 内 input_audio 多模态，
///   认证头 api-key:，asr_options.language=auto/zh/en）；
/// - custom：自定义端点（填写完整端点 URL，原样请求，不做路径加工）。
enum OnlineASRApiType: String, CaseIterable, Codable {
    case openai
    case mimo
    case custom

    static let key = "onlineASRApiType"

    var label: String {
        switch self {
        case .openai: return "OpenAI Compatible"
        case .mimo: return "Xiaomi MiMo"
        case .custom: return "Custom Endpoint"
        }
    }

    /// 按类型的默认 Base URL。
    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .mimo: return "https://api.xiaomimimo.com/v1"
        case .custom: return ""
        }
    }

    /// 按类型的默认模型名。
    var defaultModel: String {
        switch self {
        case .openai: return "whisper-1"
        case .mimo: return "mimo-v2.5-asr"
        case .custom: return "whisper-1"
        }
    }

    static var current: OnlineASRApiType {
        OnlineASRApiType(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .openai
    }
}

/// 音频分片模式（UserDefaults "audioChunkingMode"）：
/// - off：所有识别引擎关闭分片，保持 1.4 原实时识别流程；
/// - localOnly：Whisper / Qwen / Nemotron 启用分片，Online API 跳过；
/// - onlineOnly：Online ASR 启用分片，本地引擎跳过。
enum AudioChunkingMode: String, CaseIterable, Codable {
    case off
    case localOnly
    case onlineOnly

    static let key = "audioChunkingMode"

    var label: String {
        switch self {
        case .off: return "关闭"
        case .localOnly: return "仅本地模型"
        case .onlineOnly: return "仅在线 API"
        }
    }

    /// 说明文字（设置页展示应用范围）。
    var appliesToText: String {
        switch self {
        case .off: return ""
        case .localOnly: return "应用于：Whisper / Qwen / Nemotron"
        case .onlineOnly: return "应用于：Online ASR"
        }
    }

    /// 当前保存的模式。
    static var current: AudioChunkingMode {
        AudioChunkingMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .off
    }
}

/// 音频分片参数（UserDefaults 持久化；运行时读取，修改立即生效）。
enum AudioChunkingConfig {
    enum Keys {
        static let minSeconds = "audioChunkingMinSeconds"
        static let maxWaitSeconds = "audioChunkingMaxWaitSeconds"
    }

    static let minChunkRange = 1.0...10.0
    static let maxWaitRange = 3.0...15.0

    /// 最短识别时间（聚合发送下限，1-10 秒，默认 3）。
    static var minChunkSeconds: Double {
        let value = UserDefaults.standard.double(forKey: Keys.minSeconds)
        return minChunkRange.contains(value) ? value : 3
    }

    /// 最长等待时间（聚合发送兜底，3-15 秒，默认 5）。
    static var maxWaitSeconds: Double {
        let value = UserDefaults.standard.double(forKey: Keys.maxWaitSeconds)
        return maxWaitRange.contains(value) ? value : 5
    }
}

/// ASR 配置：识别引擎 / 自定义模型路径 / 在线识别 API / 音频分片。
@Observable
final class ASRConfiguration {
    /// 自定义 GGML/GGUF 模型路径（resolveModelPath 中优先级最高；留空用已下载模型）。
    var customModelPath = "" {
        didSet { UserDefaults.standard.set(customModelPath, forKey: "modelPath") }
    }

    /// 识别引擎（auto = 按模型自动判定）。
    var asrEngine: ASREngineSelection = .auto {
        didSet { UserDefaults.standard.set(asrEngine.rawValue, forKey: ASREngineSelection.key) }
    }

    /// 识别语言（ISO-639-1 码，如 "zh" / "en"；"auto" = 自动检测）。
    /// 仅对支持手动指定的引擎生效（whisper / nemotron / 在线）；
    /// Qwen 自动检测、Apple 按语言包设置（见 effectiveASRLanguage）。
    var asrLanguage = "auto" {
        didSet { UserDefaults.standard.set(asrLanguage, forKey: "asrLanguage") }
    }

    /// 生效的识别语言（nil = 自动检测）：asrLanguage 非 auto/空时的值。
    var effectiveASRLanguage: String? {
        let value = asrLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || value == "auto" ? nil : value
    }

    // 在线识别 API（OpenAI 兼容 Whisper API）。
    var onlineASREnabled = false {
        didSet { UserDefaults.standard.set(onlineASREnabled, forKey: OnlineASRConfig.Keys.enabled) }
    }
    var onlineASRBaseURL = "" {
        didSet { UserDefaults.standard.set(onlineASRBaseURL, forKey: OnlineASRConfig.Keys.baseURL) }
    }
    var onlineASRApiKey = "" {
        didSet { UserDefaults.standard.set(onlineASRApiKey, forKey: OnlineASRConfig.Keys.apiKey) }
    }
    var onlineASRModel = "" {
        didSet { UserDefaults.standard.set(onlineASRModel, forKey: OnlineASRConfig.Keys.model) }
    }
    /// API 类型：OpenAI Compatible / MiMo / Custom Endpoint。
    var onlineASRApiType: OnlineASRApiType = .openai {
        didSet { UserDefaults.standard.set(onlineASRApiType.rawValue, forKey: OnlineASRApiType.key) }
    }
    /// 流式输出（仅 MiMo 类型生效；默认关闭 = 非流式）。
    var onlineASRStreaming = false {
        didSet { UserDefaults.standard.set(onlineASRStreaming, forKey: OnlineASRConfig.Keys.streaming) }
    }
    /// MiMo 指定语种（auto / zh / en，默认 auto；文档推荐显式指定提升准确率）。
    var onlineASRMimoLanguage = "auto" {
        didSet { UserDefaults.standard.set(onlineASRMimoLanguage, forKey: OnlineASRConfig.Keys.mimoLanguage) }
    }

    // 远程自托管识别端点（OpenAI 兼容协议，局域网 GPU 机器；密钥可选）。
    var remoteASREnabled = false {
        didSet { UserDefaults.standard.set(remoteASREnabled, forKey: RemoteASRConfig.Keys.enabled) }
    }
    var remoteASRBaseURL = "" {
        didSet { UserDefaults.standard.set(remoteASRBaseURL, forKey: RemoteASRConfig.Keys.baseURL) }
    }
    var remoteASRApiKey = "" {
        didSet { UserDefaults.standard.set(remoteASRApiKey, forKey: RemoteASRConfig.Keys.apiKey) }
    }
    var remoteASRModel = "" {
        didSet { UserDefaults.standard.set(remoteASRModel, forKey: RemoteASRConfig.Keys.model) }
    }

    /// 音频分片模式（统一策略：关闭 / 仅本地模型 / 仅在线 API）。
    var audioChunkingMode: AudioChunkingMode = .off {
        didSet { UserDefaults.standard.set(audioChunkingMode.rawValue, forKey: AudioChunkingMode.key) }
    }
    /// 最短识别时间（1-10 秒，默认 3）：分片开启时生效。
    var audioChunkingMinSeconds: Double = 3 {
        didSet { UserDefaults.standard.set(audioChunkingMinSeconds, forKey: AudioChunkingConfig.Keys.minSeconds) }
    }
    /// 最长等待时间（3-15 秒，默认 5）：分片开启时生效。
    var audioChunkingMaxWaitSeconds: Double = 5 {
        didSet { UserDefaults.standard.set(audioChunkingMaxWaitSeconds, forKey: AudioChunkingConfig.Keys.maxWaitSeconds) }
    }

    /// 输入补零时长（秒）：推理输入对齐固定时长桶，0 = 禁用桶化。
    /// InputBucketing.configuredPadSeconds 读同一键（键名不可改，旧配置兼容）。
    var padSeconds: Double = 0.5 {
        didSet { UserDefaults.standard.set(padSeconds, forKey: Self.padSecondsKey) }
    }

    /// 模型下载源："hf"（官方直连）/ "mirror"（国内镜像）。
    /// ModelDownloader.DownloadSource.current 读同一键，下载时按此重写域名。
    var modelDownloadSource = "hf" {
        didSet { UserDefaults.standard.set(modelDownloadSource, forKey: Self.modelDownloadSourceKey) }
    }

    static let padSecondsKey = "asrPadSeconds"
    static let modelDownloadSourceKey = "modelDownloadSource"

    // Apple Speech（macOS 26 原生 Speech 框架）。
    /// 识别语言（默认 zh_CN；AppleSpeechManager.localeIdentifier 读取同键）。
    /// 默认值用 Apple Speech 的规范 id（下划线）；历史遗留的 "zh-CN"
    /// 由 AppleLanguageManager.isSameLocale 归一比较兜底。
    var appleSpeechLocale = "zh_CN" {
        didSet { UserDefaults.standard.set(appleSpeechLocale, forKey: "appleSpeechLocale") }
    }
    // 注：此前的 `appleSpeechOnDevice`（设置页开关）已移除——AppleSpeechEngine
    // 走 SpeechAnalyzer，**本就是纯 on-device**（无云端回落路径），该开关
    // 全仓没有任何读取点，是个纯装饰开关。留着会误导用户以为可以关闭本地识别。

    init() { reload() }

    func reload() {
        let defaults = UserDefaults.standard
        customModelPath = defaults.string(forKey: "modelPath") ?? ""
        asrEngine = ASREngineSelection(rawValue: defaults.string(forKey: ASREngineSelection.key) ?? "")
            ?? .auto
        if let savedLanguage = defaults.string(forKey: "asrLanguage"), !savedLanguage.isEmpty {
            asrLanguage = savedLanguage
        }
        onlineASREnabled = defaults.bool(forKey: OnlineASRConfig.Keys.enabled)
        onlineASRBaseURL = defaults.string(forKey: OnlineASRConfig.Keys.baseURL) ?? ""
        onlineASRApiKey = defaults.string(forKey: OnlineASRConfig.Keys.apiKey) ?? ""
        onlineASRModel = defaults.string(forKey: OnlineASRConfig.Keys.model) ?? ""
        onlineASRApiType = OnlineASRApiType(rawValue: defaults.string(forKey: OnlineASRApiType.key) ?? "")
            ?? .openai
        onlineASRStreaming = defaults.bool(forKey: OnlineASRConfig.Keys.streaming)
        let mimoLang = defaults.string(forKey: OnlineASRConfig.Keys.mimoLanguage) ?? "auto"
        onlineASRMimoLanguage = ["auto", "zh", "en"].contains(mimoLang) ? mimoLang : "auto"
        audioChunkingMode = AudioChunkingMode(rawValue: defaults.string(forKey: AudioChunkingMode.key) ?? "")
            ?? .off
        let minChunk = defaults.double(forKey: AudioChunkingConfig.Keys.minSeconds)
        audioChunkingMinSeconds = AudioChunkingConfig.minChunkRange.contains(minChunk) ? minChunk : 3
        let maxWait = defaults.double(forKey: AudioChunkingConfig.Keys.maxWaitSeconds)
        audioChunkingMaxWaitSeconds = AudioChunkingConfig.maxWaitRange.contains(maxWait) ? maxWait : 5
        // 键缺失 = 历史默认（0.5s 桶化 / 官方直连），不能把「未设置」读成 0
        //（0 的含义是「禁用桶化」，语义相反）。
        padSeconds = defaults.object(forKey: Self.padSecondsKey) == nil
            ? 0.5 : defaults.double(forKey: Self.padSecondsKey)
        modelDownloadSource = defaults.string(forKey: Self.modelDownloadSourceKey) ?? "hf"
        appleSpeechLocale = defaults.string(forKey: "appleSpeechLocale") ?? "zh_CN"
    }
}

// MARK: - 翻译配置

@Observable
final class TranslationConfiguration {
    @ObservationIgnored weak var appState: AppState?

    /// 翻译方式：唯一写入口是 AppState.setTranslationMode（联动字幕浮层状态机）。
    var mode: TranslationMode {
        get { appState?.translationMode ?? TranslationMode.current }
        set {
            if let appState {
                appState.setTranslationMode(newValue)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: "translationMode")
            }
        }
    }

    var targetLanguage = "" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage") }
    }
    var endpoint = "" {
        didSet { UserDefaults.standard.set(endpoint, forKey: TranslationService.ConfigKeys.endpoint) }
    }
    var apiKey = "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: TranslationService.ConfigKeys.apiKey) }
    }
    var model = "" {
        didSet { UserDefaults.standard.set(model, forKey: TranslationService.ConfigKeys.model) }
    }
    var timeout = 30.0 {
        didSet { UserDefaults.standard.set(timeout, forKey: TranslationService.ConfigKeys.timeout) }
    }
    var maxContext = 16000 {
        didSet { UserDefaults.standard.set(maxContext, forKey: TranslationService.ConfigKeys.maxContext) }
    }
    var temperature = 0.3 {
        didSet { UserDefaults.standard.set(temperature, forKey: TranslationService.ConfigKeys.temperature) }
    }
    /// 自定义翻译系统提示词（空 = 默认翻译指令）。
    /// 支持变量 {source_lang} / {target_lang} / {text}（PromptBuilder 统一替换）。
    var systemPrompt = "" {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: TranslationService.ConfigKeys.systemPrompt) }
    }
    /// 当前选中的提示词预设名（"自定义" = 用户编辑态；空 = 未选择过）。
    var translationPromptPreset: String {
        get { UserDefaults.standard.string(forKey: "translationPromptPreset") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "translationPromptPreset") }
    }

    /// 思考模式控制（TranslationService.ThinkingControl.current 读同一键）。
    /// 值域 = ThinkingControl.rawValue；旧值 "off" 由读取端并入 auto。
    var thinkingControlRaw = "auto" {
        didSet { UserDefaults.standard.set(thinkingControlRaw, forKey: Self.thinkingControlKey) }
    }

    /// 上下文句数（0-8，默认 2；0 = 关闭）。TranslationService 组请求时读同一键。
    var contextRounds = 2 {
        didSet { UserDefaults.standard.set(contextRounds, forKey: Self.contextRoundsKey) }
    }

    static let thinkingControlKey = "translationThinkingControl"
    static let contextRoundsKey = "translationContextRounds"

    /// 磁盘上的翻译方式（TranslationMode.current 直读 UserDefaults，不经过
    /// appState 内存副本）：备份恢复后用它把运行时状态拉回来。
    var modeFromDefaults: TranslationMode { TranslationMode.current }

    init() { reload() }

    func reload() {
        let defaults = UserDefaults.standard
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? ""
        endpoint = defaults.string(forKey: TranslationService.ConfigKeys.endpoint) ?? ""
        apiKey = defaults.string(forKey: TranslationService.ConfigKeys.apiKey) ?? ""
        model = defaults.string(forKey: TranslationService.ConfigKeys.model) ?? ""
        let timeout = defaults.double(forKey: TranslationService.ConfigKeys.timeout)
        self.timeout = timeout == 0 ? 30 : timeout
        let maxContext = defaults.integer(forKey: TranslationService.ConfigKeys.maxContext)
        self.maxContext = maxContext == 0 ? 16000 : maxContext
        let temperature = defaults.double(forKey: TranslationService.ConfigKeys.temperature)
        self.temperature = defaults.object(forKey: TranslationService.ConfigKeys.temperature) == nil
            ? 0.3 : temperature
        systemPrompt = defaults.string(forKey: TranslationService.ConfigKeys.systemPrompt) ?? ""
        thinkingControlRaw = defaults.string(forKey: Self.thinkingControlKey) ?? "auto"
        // 键缺失 = 历史默认 2；不能把「未设置」读成 0（0 的含义是关闭上下文）。
        contextRounds = defaults.object(forKey: Self.contextRoundsKey) == nil
            ? 2 : max(0, min(8, defaults.integer(forKey: Self.contextRoundsKey)))
    }
}

// MARK: - 字幕配置

/// 字幕样式设置：全部代理到 AppState（setter 会同步持久化并实时联动字幕浮层）。
/// 属性读取经由 AppState（@Observable），页面刷新依赖跟踪不受影响。
@Observable
final class SubtitleConfiguration {
    @ObservationIgnored weak var appState: AppState?

    var sourceFontSize: Double {
        get { appState?.subtitleOverlaySourceFontSize ?? 32 }
        set { appState?.setSubtitleOverlaySourceFontSize(newValue) }
    }
    var translationFontSize: Double {
        get { appState?.subtitleOverlayTranslationFontSize ?? 24 }
        set { appState?.setSubtitleOverlayTranslationFontSize(newValue) }
    }
    var fontWeight: String {
        get { appState?.subtitleFontWeight ?? "regular" }
        set { appState?.setSubtitleFontWeight(newValue) }
    }
    var lineSpacing: Double {
        get { appState?.subtitleLineSpacing ?? 0 }
        set { appState?.setSubtitleLineSpacing(newValue) }
    }
    var horizontalAlignment: String {
        get { appState?.subtitleHorizontalAlignment ?? "left" }
        set { appState?.setSubtitleHorizontalAlignment(newValue) }
    }
    var maxLines: Int {
        get { appState?.maxSubtitleLines ?? 2 }
        set { appState?.setMaxSubtitleLines(newValue) }
    }
    var containerWidth: Double {
        get { appState?.subtitleContainerWidth ?? 800 }
        set { appState?.setSubtitleContainerWidth(newValue) }
    }
    var containerHeight: Double {
        get { appState?.subtitleContainerHeight ?? 200 }
        set { appState?.setSubtitleContainerHeight(newValue) }
    }
    var backgroundOpacity: Double {
        get { appState?.subtitleBackgroundOpacity ?? 0.4 }
        set { appState?.setSubtitleBackgroundOpacity(newValue) }
    }
    var borderOpacity: Double {
        get { appState?.subtitleOverlayBorderOpacity ?? 0.08 }
        set { appState?.setSubtitleOverlayBorderOpacity(newValue) }
    }
    var editBorderVisible: Bool {
        get { appState?.subtitleEditBorderVisible ?? true }
        set { appState?.setSubtitleEditBorderVisible(newValue) }
    }
    var editBorderColorHex: String {
        get { appState?.subtitleEditBorderColorHex ?? "FFFFFF" }
        set { appState?.setSubtitleEditBorderColorHex(newValue) }
    }
    var editBorderOpacity: Double {
        get { appState?.subtitleEditBorderOpacity ?? 0.6 }
        set { appState?.setSubtitleEditBorderOpacity(newValue) }
    }
    var clearDelay: Double {
        get { appState?.subtitleClearDelay ?? 3 }
        set { appState?.setSubtitleClearDelay(newValue) }
    }
    func resetOverlayPosition() {
        appState?.resetFloatingOverlayPosition()
    }

    /// 备份恢复后：把 UserDefaults 中的字幕样式应用到运行时。
    ///
    /// 为什么需要：字幕样式在 AppState 里是**内存副本**（浮层实时渲染读内存），
    /// 只写 UserDefaults 不会生效；而 AppState 的 setter 会把内存旧值写回磁盘，
    /// 用户下一次动设置就把刚恢复的值覆盖掉。经 setter 逐项应用（setter 内部
    /// 自带范围钳制与持久化），保证磁盘与运行时一致。
    /// 默认值与 AppState 初始化器一致（键缺失时用它兜底）。
    func applyFromDefaults() {
        guard let appState else { return }
        let d = UserDefaults.standard
        func number(_ key: String) -> Double? {
            (d.object(forKey: key) as? NSNumber)?.doubleValue
        }
        func flag(_ key: String) -> Bool? {
            (d.object(forKey: key) as? NSNumber)?.boolValue
        }
        appState.setSubtitleOverlaySourceFontSize(number("subtitleOverlaySourceFontSize") ?? 32)
        appState.setSubtitleOverlayTranslationFontSize(number("subtitleOverlayTranslationFontSize") ?? 24)
        appState.setSubtitleOverlayBorderOpacity(number("subtitleOverlayBorderOpacity") ?? 0.08)
        appState.setMaxSubtitleLines(d.object(forKey: "subtitleMaxLines") as? Int ?? 2)
        appState.setSubtitleHorizontalAlignment(d.string(forKey: "subtitleHorizontalAlignment") ?? "left")
        appState.setSubtitleClearDelay(number("subtitleClearDelay") ?? 3)
        appState.setSubtitleContainerWidth(number("subtitleFrameWidth") ?? 800)
        appState.setSubtitleContainerHeight(number("subtitleFrameHeight") ?? 200)
        appState.setSubtitleBackgroundOpacity(number("subtitleBackgroundOpacity") ?? 0.4)
        appState.setSubtitleEditBorderVisible(flag("subtitleEditBorderVisible") ?? true)
        appState.setSubtitleEditBorderColorHex(d.string(forKey: "subtitleEditBorderColorHex") ?? "FFFFFF")
        appState.setSubtitleEditBorderOpacity(number("subtitleEditBorderOpacity") ?? 0.6)
        appState.setSubtitleFontWeight(d.string(forKey: "subtitleFontWeight") ?? "medium")
        appState.setSubtitleLineSpacing(number("subtitleLineSpacing") ?? 0)
    }
}

// MARK: - 音频配置

@Observable
final class AudioConfiguration {
    /// 录制时默认包含麦克风（浮层内仍可临时切换；AudioRecorder/选择面板初值读此键）。
    var defaultIncludeMicrophone = false {
        didSet { UserDefaults.standard.set(defaultIncludeMicrophone, forKey: Self.includeMicrophoneKey) }
    }

    static let includeMicrophoneKey = "defaultIncludeMicrophone"

    init() { reload() }

    func reload() {
        defaultIncludeMicrophone = UserDefaults.standard.bool(forKey: Self.includeMicrophoneKey)
    }
}

// MARK: - 窗口配置

/// 浮层窗口偏好（设置页经本配置修改，联动 AppState/浮层）。
@Observable
final class WindowConfiguration {
    @ObservationIgnored weak var appState: AppState?

    /// 字幕浮层自动隐藏工具栏（代理 AppState，浮层实时联动）。
    var autoHideControls: Bool {
        get { appState?.floatingOverlayAutoHide ?? false }
        set { appState?.setFloatingOverlayAutoHide(newValue) }
    }
}

// MARK: - 配置中心

/// 配置中心：设置页面唯一绑定入口。
@Observable
final class ConfigurationManager {
    static let shared = ConfigurationManager()

    /// API 服务器 / 转录字体等通用配置。
    let general = GeneralSettings()
    /// ASR：识别引擎 / 模型路径 / 在线识别 / 音频分片。
    let asr = ASRConfiguration()
    /// 翻译：方式 / 端点 / 密钥 / 模型 / 上下文参数。
    let translation = TranslationConfiguration()
    /// 字幕样式（代理 AppState，实时联动浮层）。
    let subtitle = SubtitleConfiguration()
    /// 录音配置。
    let audio = AudioConfiguration()
    /// 浮层窗口偏好。
    let window = WindowConfiguration()
    /// ASR 识别提示词（热词注入）配置。
    let asrPrompt = ASRPromptConfiguration()

    private init() {
        ConfigurationSchema.migrateIfNeeded()
    }

    /// App 启动时注入 AppState：字幕/翻译/窗口配置需要经 AppState setter 联动浮层。
    func attach(appState: AppState) {
        general.appState = appState
        translation.appState = appState
        subtitle.appState = appState
        window.appState = appState
    }

    /// 从 UserDefaults 重新同步外部直接写入的变更（页面 onAppear 调用）。
    func reload() {
        general.reload()
        asr.reload()
        translation.reload()
        audio.reload()
        // asrPrompt 同属配置分区：此前漏刷，外部直接写这些键（备份恢复、
        // 旧版本迁移）后内存值一直是旧的。
        asrPrompt.reload()
        ConfigurationSchema.migrateIfNeeded()
    }

    /// 备份恢复专用：reload 之外还要把值**应用到运行时**。
    ///
    /// reload 只刷新配置对象的内存副本；而运行时状态（翻译方式、字幕浮层样式、
    /// 浮层自动隐藏）由 AppState 持有，且其 setter 会把内存旧值写回磁盘 ——
    /// 不应用的话，恢复后的值会被下一次设置变更覆盖。AppState 未注入时
    /// （理论不可达：App 启动即 attach）退化为仅 reload。
    func reloadAndApplyRuntime() {
        reload()
        guard let appState = subtitle.appState else { return }
        appState.setTranslationMode(translation.modeFromDefaults)
        subtitle.applyFromDefaults()
        appState.setFloatingOverlayAutoHide(
            UserDefaults.standard.bool(forKey: "floatingOverlayAutoHide"))
    }
}