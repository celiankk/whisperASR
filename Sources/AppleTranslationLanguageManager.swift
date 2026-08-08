import Foundation
import Translation

// MARK: - Apple Translation 语言资源管理（AppleTranslationLanguageManager）
//
// 独立的翻译语言资源检测（不复用 Speech 语言列表——两个模块语言资源
// 互相独立）：
// - macOS 15+：LanguageAvailability.supportedLanguages + status 过滤，
//   只返回已安装（installed）的翻译语言；
// - 低版本：返回空（框架不可用）。
//
// 供 AppleServiceStatusManager 的翻译语言资源判断使用。

/// 一条 Apple Translation 语言资源。
struct AppleTranslationLanguage: Identifiable, Equatable {
    let identifier: String
    let displayName: String
    let locale: Locale.Language
    /// 语言包已安装（可直接使用）。
    let isInstalled: Bool

    var id: String { identifier }
}

final class AppleTranslationLanguageManager: @unchecked Sendable {
    static let shared = AppleTranslationLanguageManager()

    private init() {}

    /// 已安装的翻译语言（语言包在本地，可直接使用）。
    func installedLanguages() async -> [AppleTranslationLanguage] {
        guard #available(macOS 15, *) else { return [] }
        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        var result: [AppleTranslationLanguage] = []
        for language in supported {
            guard let status = try? await availability.status(for: "test", to: language),
                  status == .installed else { continue }
            let identifier = language.minimalIdentifier
            result.append(AppleTranslationLanguage(
                identifier: identifier,
                displayName: Locale.current.localizedString(forIdentifier: identifier) ?? identifier,
                locale: language,
                isInstalled: true
            ))
        }
        return result.sorted { $0.displayName < $1.displayName }
    }
}
