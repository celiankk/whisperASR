import Foundation
import Observation

// MARK: - 设置数据中心（SettingsManager）
//
// 所有设置页面只绑定这里的数据，不直接触碰业务逻辑：
// - UserDefaults 键与旧 @AppStorage 完全一致，业务代码读取路径不变；
// - 需要联动字幕浮层/状态机的写入（字幕样式、翻译方式）转发 AppState setter；
// - 外部入口（快速切换菜单、URL Scheme 等）可能直接写 UserDefaults，
//   页面 onAppear 调 SettingsManager.reload() 吸收外部变更。

@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    let general = GeneralSettings()
    let recognition = RecognitionSettings()
    let translation = TranslationSettings()
    let caption = CaptionSettings()
    let audio = AudioSettings()

    private init() {}

    /// App 启动时注入 AppState：字幕样式/翻译方式需要经 AppState setter 联动浮层。
    func attach(appState: AppState) {
        general.appState = appState
        translation.appState = appState
        caption.appState = appState
    }

    /// 从 UserDefaults 重新同步外部直接写入的变更（页面 onAppear 调用）。
    func reload() {
        general.reload()
        recognition.reload()
        translation.reload()
        audio.reload()
    }
}

// MARK: - 通用

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

    init() { reload() }

    func reload() {
        let defaults = UserDefaults.standard
        transcriptFontSizeRaw = defaults.string(forKey: "transcriptFontSize")
            ?? TranscriptFontSize.normal.rawValue
        apiServerEnabled = defaults.bool(forKey: APIKeys.enabled)
        let port = defaults.integer(forKey: APIKeys.port)
        apiServerPort = port == 0 ? APIKeys.defaultPort : port
        apiServerToken = defaults.string(forKey: APIKeys.token) ?? ""
        apiServerAllowLAN = defaults.bool(forKey: APIKeys.allowLAN)
        apiServerVerboseLog = defaults.bool(forKey: APIKeys.verboseLog)
    }
}

// MARK: - 识别

@Observable
final class RecognitionSettings {
    /// 自定义 GGML/GGUF 模型路径（resolveModelPath 中优先级最高；留空用已下载模型）。
    var customModelPath = "" {
        didSet { UserDefaults.standard.set(customModelPath, forKey: "modelPath") }
    }

    init() { reload() }

    func reload() {
        customModelPath = UserDefaults.standard.string(forKey: "modelPath") ?? ""
    }
}

// MARK: - 翻译

@Observable
final class TranslationSettings {
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
    }
}

// MARK: - 字幕

/// 字幕样式设置：全部代理到 AppState（setter 会同步持久化并实时联动字幕浮层）。
/// 属性读取经由 AppState（@Observable），页面刷新依赖跟踪不受影响。
@Observable
final class CaptionSettings {
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
    var minSpeechDuration: Double {
        get { appState?.subtitleMinSpeechDuration ?? 1 }
        set { appState?.setSubtitleMinSpeechDuration(newValue) }
    }
    var maxSentenceDuration: Double {
        get { appState?.subtitleMaxSentenceDuration ?? 8 }
        set { appState?.setSubtitleMaxSentenceDuration(newValue) }
    }
    var silencePause: Double {
        get { appState?.subtitleSilencePause ?? 1 }
        set { appState?.setSubtitleSilencePause(newValue) }
    }
    var autoHideControls: Bool {
        get { appState?.floatingOverlayAutoHide ?? false }
        set { appState?.setFloatingOverlayAutoHide(newValue) }
    }

    func resetOverlayPosition() {
        appState?.resetFloatingOverlayPosition()
    }
}

// MARK: - 音频

@Observable
final class AudioSettings {
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
