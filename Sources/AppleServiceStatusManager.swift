import Foundation
import Observation
import Speech
import Translation

// MARK: - Apple 服务状态管理器（AppleServiceStatusManager）
//
// 统一管理 Apple Speech / Apple Translation 的运行时能力状态，
// View 不自行判断（只读本管理器快照）。
//
// 状态检测原则（非硬编码版本判断）：
// - #available(macOS xx) 编译期分支（运行时真值）；
// - Framework 是否存在（系统路径 + Bundle 探测）；
// - API 是否可调用（会话能否创建）；
// - 语言资源状态（LanguageAvailability：installed / supported / unsupported）。
//
// 刷新时机（不轮询）：
// - 应用启动检测一次（AppRuntimeManager.attach）；
// - 进入 Apple 服务页面自动刷新（onAppear）；
// - 系统语言变化重新检测（NSLocale.currentLocaleDidChangeNotification）。
//
// 调试日志：authorizationStatus / supportedLocales / currentLocale；
// frameworkAvailable / sessionAvailable / languageAvailable。

@Observable
final class AppleServiceStatusManager {
    static let shared = AppleServiceStatusManager()

    // MARK: - Apple Speech 状态

    enum SpeechAuth: String {
        case notDetermined = "未请求"
        case authorized = "已授权"
        case denied = "被拒绝"
        case restricted = "受限"
    }

    /// 授权状态。
    private(set) var speechAuth: SpeechAuth = .notDetermined
    /// 服务可用（已授权且可创建识别器）。
    private(set) var speechServiceAvailable = false
    /// 当前选择语言（如 zh-CN）。
    private(set) var speechCurrentLocale = AppleSpeechProvider.localeIdentifier
    /// 当前语言已安装（在已安装语言列表中）。
    private(set) var speechLocaleSupported = false
    /// 设备支持离线（on-device）识别。
    private(set) var speechOfflineAvailable = false
    /// 本机已安装的识别语言数量（可直接离线使用）。
    private(set) var speechInstalledLocaleCount = 0

    // MARK: - Apple Translation 状态

    enum TranslationState: String {
        case available = "Available"
        case needLanguageResource = "Need Language Resource"
        case unavailable = "Unavailable"
        case error = "Error"
    }

    /// Translation Framework 是否存在。
    private(set) var translationFrameworkAvailable = false
    /// 当前系统支持 Translation 框架 API（macOS 15+）。
    private(set) var translationSystemSupported = false
    /// 可创建翻译会话（macOS 26+ 程序化 API；15-25 仅 SwiftUI 环境注入）。
    private(set) var translationSessionAvailable = false
    /// 目标语言资源（installed / supported）。
    private(set) var translationLanguageAvailable = false
    /// 目标语言需要下载语言包（支持但未安装）。
    private(set) var translationLanguageNeedsDownload = false
    /// 综合状态。
    private(set) var translationState: TranslationState = .unavailable
    /// 当前目标语言（配置的 targetLanguage）。
    private(set) var translationTargetLanguage = ""
    /// 已安装的翻译语言数量（AppleTranslationLanguageManager 独立检测）。
    private(set) var translationInstalledLanguageCount = 0

    // MARK: - 生命周期

    private init() {
        // 系统语言变化：重新检测（不轮询）。
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            AppLogger.shared.log(.engine, "Apple services: locale changed, re-detecting")
            Task { await self.refresh() }
        }
    }

    /// 全量检测（启动 / 进入页面 / 语言变化时调用；内部防并发）。
    private let refreshLock = NSLock()
    private var refreshing = false

    func refresh() async {
        refreshLock.lock()
        guard !refreshing else {
            refreshLock.unlock()
            return
        }
        refreshing = true
        refreshLock.unlock()
        defer { refreshLock.lock(); refreshing = false; refreshLock.unlock() }

        await refreshSpeech()
        await refreshTranslation()
        logDebugState()
    }

    // MARK: - Speech 检测

    private func refreshSpeech() async {
        switch AppleSpeechProvider.authorizationStatus {
        case .authorized:
            speechAuth = .authorized
        case .denied:
            speechAuth = .denied
        case .restricted:
            speechAuth = .restricted
        case .notDetermined:
            speechAuth = .notDetermined
        @unknown default:
            speechAuth = .restricted
        }

        // 已安装语言（本机可直接离线使用；不含"支持但未下载/需要下载"）。
        let installed = await AppleSpeechLanguageManager.shared.installedLanguages()
        speechInstalledLocaleCount = installed.count
        speechCurrentLocale = AppleSpeechProvider.localeIdentifier
        speechLocaleSupported = installed.contains { $0.identifier == speechCurrentLocale }

        // 服务可用：已授权且能创建识别器（locale 不支持时 Provider 会回退 en-US）。
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: speechCurrentLocale))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer else {
            speechServiceAvailable = false
            speechOfflineAvailable = false
            return
        }
        speechServiceAvailable = speechAuth == .authorized
        // 离线可用：设备能力 + 授权（不依赖语言包下载状态）。
        speechOfflineAvailable = speechAuth == .authorized && recognizer.supportsOnDeviceRecognition
    }

    // MARK: - Translation 检测

    private func refreshTranslation() async {
        // 1. Framework 是否存在（系统路径 + Bundle 双探测）。
        translationFrameworkAvailable = FileManager.default.fileExists(
            atPath: "/System/Library/Frameworks/Translation.framework")
            || Bundle(identifier: "com.apple.Translation") != nil

        // 2. 当前系统是否支持（#available 运行时真值）。
        translationSystemSupported = if #available(macOS 15, *) { true } else { false }

        guard translationFrameworkAvailable, translationSystemSupported else {
            translationSessionAvailable = false
            translationLanguageAvailable = false
            translationLanguageNeedsDownload = false
            translationState = .unavailable
            return
        }

        // 3. 目标语言（配置的 targetLanguage；缺省用 zh-Hans）。
        let configured = ConfigurationManager.shared.translation.targetLanguage
        translationTargetLanguage = configured.isEmpty ? "zh-Hans" : configured
        let target = Locale.Language(identifier: translationTargetLanguage)

        // 4. 语言资源状态（LanguageAvailability，macOS 15+ 运行时能力检测）。
        // 已安装翻译语言数量（独立于 Speech 语言资源）。
        translationInstalledLanguageCount = await AppleTranslationLanguageManager
            .shared.installedLanguages().count
        if #available(macOS 15, *) {
            let availability = LanguageAvailability()
            let status: LanguageAvailability.Status
            do {
                status = try await availability.status(for: "test", to: target)
            } catch {
                // 能力探测失败 → Error（初始化失败）。
                translationLanguageAvailable = false
                translationLanguageNeedsDownload = false
                translationSessionAvailable = false
                translationState = .error
                return
            }
            switch status {
            case .installed:
                translationLanguageAvailable = true
                translationLanguageNeedsDownload = false
            case .supported:
                translationLanguageAvailable = false
                translationLanguageNeedsDownload = true
            case .unsupported:
                translationLanguageAvailable = false
                translationLanguageNeedsDownload = false
            @unknown default:
                translationLanguageAvailable = false
                translationLanguageNeedsDownload = false
            }
        } else {
            translationLanguageAvailable = false
            translationLanguageNeedsDownload = false
        }

        // 5. 会话是否可创建（macOS 26+ 程序化 API；15-25 仅 SwiftUI 环境注入）。
        if #available(macOS 26, *) {
            translationSessionAvailable = true
        } else {
            translationSessionAvailable = false
        }

        // 综合状态：语言包缺失 → Need Language Resource；否则 Available。
        if !translationLanguageAvailable && translationLanguageNeedsDownload {
            translationState = .needLanguageResource
        } else if translationLanguageAvailable && translationSessionAvailable {
            translationState = .available
        } else if translationLanguageAvailable {
            // 语言资源有但会话不可创建（15-25）：初始化受限。
            translationState = .error
        } else {
            translationState = .unavailable
        }
    }

    // MARK: - 日志

    private func logDebugState() {
        AppLogger.shared.log(
            .engine,
            "Apple Speech: authorizationStatus=\(speechAuth.rawValue) "
                + "installedLocales=\(speechInstalledLocaleCount) "
                + "currentLocale=\(speechCurrentLocale) "
                + "serviceAvailable=\(speechServiceAvailable) "
                + "offlineAvailable=\(speechOfflineAvailable)"
        )
        AppLogger.shared.log(
            .engine,
            "Apple Translation: frameworkAvailable=\(translationFrameworkAvailable) "
                + "sessionAvailable=\(translationSessionAvailable) "
                + "languageAvailable=\(translationLanguageAvailable) "
                + "state=\(translationState.rawValue)"
        )
    }
}
