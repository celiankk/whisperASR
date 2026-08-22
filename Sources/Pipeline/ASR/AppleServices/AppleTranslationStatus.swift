import Foundation
import Translation
import Observation

// MARK: - Apple Translation 状态（AppleTranslationStatus）
//
// macOS 系统翻译框架（TranslationSession）状态层：
// - 引擎状态机：idle / initializing / available / needResource / unavailable / error；
// - 调试统计（AppleTranslationDebug）：Session 状态 / 语言状态 / 翻译耗时 / 错误；
// - 运行时能力快照（@Observable 单例，View 只读）。
//
// 能力检测（运行时，非硬编码版本判断）：
// - macOS 26+：程序化 TranslationSession(installedSource:target:) 可创建 → 真实翻译；
// - 更低版本：框架仅 SwiftUI environment 注入接口 → 如实报告不可用；
// - 语言资源：LanguageAvailability.status(for:to:)（installed / supported / unsupported）。

/// Apple Translation 引擎状态机。
enum AppleTranslationEngineState: String {
    case idle = "Idle"
    case initializing = "Initializing"
    case available = "Available"
    case needResource = "Need Resource"
    case unavailable = "Unavailable"
    case error = "Error"
}

/// 翻译语言资源状态（LanguageAvailability 结果）。
enum AppleTranslationLanguageState: String {
    case installed = "Installed"
    case supported = "Supported"
    case unsupported = "Unsupported"
    case unknown = "Unknown"
}

/// AppleTranslationDebug：Session 状态 / 语言状态 / 翻译耗时 / 错误信息。
struct AppleTranslationDebug {
    var sessionCreated = false          // TranslationSession 创建
    var languageStatus: String = "unknown"  // 语言资源状态
    var lastTranslateDuration: TimeInterval = 0
    var translateCount: Int = 0
    var lastError: String? = nil

    var summary: String {
        "session=\(sessionCreated ? "created" : "none") language=\(languageStatus) "
            + "count=\(translateCount) duration=\(Int(lastTranslateDuration * 1000))ms"
            + (lastError.map { " error=\($0)" } ?? "")
    }
}

// MARK: - 语言资源状态检测

/// 检测「目标语言」的翻译语言包状态。
///
/// 语言包状态依赖源语言：`status(from:to:)` 的源语言固定 en 时，
/// 目标语言也是 en 会返回 unsupported（系统不支持同语言翻译），误报"不可用"。
/// 实际场景源语言是语音语言（通常接近系统语言），故用多候选源语言
/// （系统语言 + en）检测：任一 installed 即离线可用。
enum AppleTranslationLanguageProbe {
    static func state(for targetLanguage: String) async -> AppleTranslationLanguageState {
        guard #available(macOS 15, *) else { return .unsupported }
        let availability = LanguageAvailability()
        let target = Locale.Language(identifier: targetLanguage)
        var best: AppleTranslationLanguageState = .unsupported
        for sourceID in sourceCandidates() {
            let status = await availability.status(
                from: Locale.Language(identifier: sourceID), to: target)
            if status == .installed { return .installed }
            if status == .supported { best = .supported }
        }
        return best
    }

    /// 检测目标语言是否已安装（离线可用）。
    static func isInstalled(_ targetLanguage: String) async -> Bool {
        await state(for: targetLanguage) == .installed
    }

    /// 源语言候选：系统语言优先（语音语言通常与其一致），en 兜底。
    private static func sourceCandidates() -> [String] {
        var candidates = [Locale.current.language.minimalIdentifier]
        if !candidates.contains("en") { candidates.append("en") }
        return candidates
    }
}

/// Apple Translation 运行时能力快照（启动 / 进页面 / 语言变化时 refresh）。
@Observable
final class AppleTranslationStatus {
    static let shared = AppleTranslationStatus()

    /// Translation Framework 是否存在。
    private(set) var frameworkAvailable = false
    /// 当前系统支持 Translation 框架 API（macOS 15+）。
    private(set) var systemSupported = false
    /// 可创建翻译会话（macOS 26+ 程序化 API；15-25 仅 SwiftUI 环境注入）。
    private(set) var sessionAvailable = false
    /// 目标语言资源状态（installed / supported / unsupported）。
    private(set) var languageStatus: AppleTranslationLanguageState = .unknown
    /// 综合状态。
    private(set) var state: AppleTranslationEngineState = .unavailable
    /// 当前目标语言（配置的 targetLanguage）。
    private(set) var targetLanguage = ""
    /// 已安装的翻译语言数量。
    private(set) var installedLanguageCount = 0

    private init() {
        // 系统语言变化：重新检测（不轮询）。
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    private let refreshLock = NSLock()
    private var refreshing = false

    /// 全量检测（防并发）。
    func refresh() async {
        refreshLock.lock()
        guard !refreshing else {
            refreshLock.unlock()
            return
        }
        refreshing = true
        refreshLock.unlock()
        defer { refreshLock.lock(); refreshing = false; refreshLock.unlock() }

        // 1. Framework 是否存在（系统路径 + Bundle 双探测）。
        frameworkAvailable = FileManager.default.fileExists(
            atPath: "/System/Library/Frameworks/Translation.framework")
            || Bundle(identifier: "com.apple.Translation") != nil

        // 2. 当前系统是否支持（#available 运行时真值）。
        systemSupported = if #available(macOS 15, *) { true } else { false }

        guard frameworkAvailable, systemSupported else {
            sessionAvailable = false
            languageStatus = .unknown
            state = .unavailable
            logDebug()
            return
        }

        // 3. 目标语言（配置的 targetLanguage；缺省用 zh-Hans）。
        let configured = ConfigurationManager.shared.translation.targetLanguage
        targetLanguage = configured.isEmpty ? "zh-Hans" : configured

        // 4. 语言资源状态（LanguageAvailability，macOS 15+ 运行时能力检测）。
        // 注意：status(for: "text", to:) 依赖文本语言识别，短文本会抛
        // unableToIdentifyLanguage；改用 status(from:to:) 多候选源语言
        // （系统语言 + en）——固定 en 时目标语言为 en 会误报 unsupported。
        // installedLanguageCount 不在此查：installedLanguages 是
        // supportedLanguages(~40+) × 2 候选源的 N+1 串行 XPC，且只有
        // Apple 服务设置页展示——改由 refreshInstalledCount() 按需查
        //（设置页 onAppear），启动路径零额外 XPC。
        languageStatus = await AppleTranslationLanguageProbe.state(for: targetLanguage)

        // 5. 会话是否可创建（macOS 26+ 程序化 API；15-25 仅 SwiftUI 环境注入）。
        sessionAvailable = if #available(macOS 26, *) { true } else { false }

        // 综合状态：会话创建能力优先；语言包缺失 → Need Resource。
        // macOS 15–25 没有程序化 TranslationSession，即使语言包已安装也
        // 应报告 unavailable（而不是 error —— 那不是初始化失败）。
        if !sessionAvailable {
            state = .unavailable
        } else if languageStatus == .supported {
            state = .needResource
        } else if languageStatus == .installed {
            state = .available
        } else {
            state = .unavailable
        }
        logDebug()
    }

    /// 按需查询已安装翻译语言数（Apple 服务设置页用；N+1 XPC 不进启动路径）。
    func refreshInstalledCount() async {
        installedLanguageCount = await AppleTranslationLanguageManager.shared.installedLanguages().count
    }

    private func logDebug() {
        AppLogger.shared.log(
            .translation,
            "AppleTranslationDebug: framework=\(frameworkAvailable) system=\(systemSupported) "
                + "session=\(sessionAvailable) language=\(languageStatus.rawValue) "
                + "target=\(targetLanguage) state=\(state.rawValue)"
        )
    }
}

// MARK: - 已安装翻译语言

/// 已安装的翻译语言数量查询（独立于 Speech 语言资源）。
final class AppleTranslationLanguageManager: @unchecked Sendable {
    static let shared = AppleTranslationLanguageManager()

    private init() {}

    /// 已安装的翻译语言（LanguageAvailability.supportedLanguages 中
    /// 任一候选源语言可 installed 的目标语言）。
    func installedLanguages() async -> [Locale.Language] {
        guard #available(macOS 15, *) else { return [] }
        let availability = LanguageAvailability()
        let all = await availability.supportedLanguages
        var installed: [Locale.Language] = []
        for lang in all {
            if await AppleTranslationLanguageProbe.isInstalled(lang.minimalIdentifier) {
                installed.append(lang)
            }
        }
        return installed
    }
}
