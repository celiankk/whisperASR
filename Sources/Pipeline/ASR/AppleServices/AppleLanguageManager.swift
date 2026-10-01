import Foundation
import Speech

// MARK: - Apple 语言管理（AppleLanguageManager）
//
// 获取本机语音识别语言资源（纯 Apple Speech Framework 能力，不手写语言列表）：
// - installedLocales（SpeechTranscriber + DictationTranscriber 并集）：
//   系统已安装资产（Installed）；
// - supportedLocales（SpeechTranscriber）：系统全部支持语言（Available，
//   其中未安装的为 Need Download）；
// - 不支持的语言：Unavailable（不在 supportedLocales 中）。
//
// 状态：Installed / Available / Need Download / Unavailable。
// 设置页只允许选择已安装语言；未安装语言禁用展示并标注状态。

/// 一条 Apple Speech 语言资源。
struct AppleLanguage: Identifiable, Equatable {
    let identifier: String
    let displayName: String
    let locale: Locale
    /// 资源状态：Installed / Available / Need Download / Unavailable。
    let resourceState: AppleLanguageResourceState

    var id: String { identifier }

    /// 已安装（语言包在本地，可直接离线使用）。
    var isInstalled: Bool { resourceState == .installed }
}

final class AppleLanguageManager: @unchecked Sendable {
    static let shared = AppleLanguageManager()

    private init() {}

    // MARK: - Locale 身份归一

    /// Apple Speech 的语言 id 用**下划线**（`zh_CN`），而配置、URL 与
    /// `Locale(identifier:)` 常见写法是**连字符**（`zh-CN`），Apple 的规范解析
    /// 还会补出脚本子标签（`zh-Hans-CN` → `zh_CN`）。用精确字符串比较会把
    /// 同一种语言判成两种（实测：本机 installedLocales 全为 `zh_CN` 形态）。
    ///
    /// 规范键取「语言 + 地区」，忽略脚本/变体/正字法——这正是上面三种写法
    /// 唯一保持一致的部分；无地区时退化为语言本身。
    static func matchKey(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        // 按 BCP-47 形态切分（zh / zh-Hans-CN / zh_CN / en_US_POSIX 都能拆对）。
        let parts = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "@" })
        guard let language = parts.first, !language.isEmpty else { return "" }
        // 地区：2 位大写字母（CN/US/TW）或 3 位数字（UN M.49，如 150）。
        let region = parts.dropFirst().first { part in
            (part.count == 2 && part.allSatisfy(\.isUppercase))
                || (part.count == 3 && part.allSatisfy(\.isNumber))
        }
        return region.map { "\(language)_\($0)" } ?? String(language)
    }

    /// 两种写法是否指同一语言资源。
    static func isSameLocale(_ lhs: String, _ rhs: String) -> Bool {
        let a = matchKey(lhs), b = matchKey(rhs)
        return !a.isEmpty && a == b
    }

    /// 已安装语言（可直接离线使用）。
    func installedLanguages() async -> [AppleLanguage] {
        let installed = await installedLocales()
        return makeLanguages(locales: installed, state: .installed)
    }

    /// 全部受支持语言（含未安装；Available / Need Download）。
    func supportedLanguages() async -> [AppleLanguage] {
        guard #available(macOS 26, *) else { return [] }
        let supported = await SpeechTranscriber.supportedLocales
        let installedKeys = Set(await installedLocales().map { Self.matchKey($0.identifier) })
        return makeLanguages(locales: supported) { locale in
            installedKeys.contains(Self.matchKey(locale.identifier)) ? .installed : .needDownload
        }
    }

    /// 支持但未安装的语言（Need Download；设置页禁用展示）。
    func unavailableLanguages() async -> [AppleLanguage] {
        guard #available(macOS 26, *) else { return [] }
        let supported = await SpeechTranscriber.supportedLocales
        let installedKeys = Set(await installedLocales().map { Self.matchKey($0.identifier) })
        let missing = supported.filter { !installedKeys.contains(Self.matchKey($0.identifier)) }
        return makeLanguages(locales: missing, state: .needDownload)
    }

    /// 当前语言资源状态（Installed / Need Download / Unavailable）。
    func resourceState(for localeIdentifier: String) async -> AppleLanguageResourceState {
        let installed = await installedLanguages()
        if installed.contains(where: { Self.isSameLocale($0.identifier, localeIdentifier) }) {
            return .installed
        }
        guard #available(macOS 26, *) else { return .unavailable }
        let resolved = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier))
        return resolved != nil ? .needDownload : .unavailable
    }

    // MARK: - 私有

    /// 已安装语言集合（macOS 26+ 系统资产查询；低版本回退空）。
    /// 使用 SpeechTranscriber（完整 ASR 识别资产）为主，
    /// 并集 DictationTranscriber（听写资产）补全，避免语言列表不全。
    private func installedLocales() async -> [Locale] {
        guard #available(macOS 26, *) else { return [] }
        let speech = await SpeechTranscriber.installedLocales
        let dictation = await DictationTranscriber.installedLocales
        return Array(Set(speech).union(dictation)).sorted { $0.identifier < $1.identifier }
    }

    private func makeLanguages(locales: [Locale], state: AppleLanguageResourceState) -> [AppleLanguage] {
        locales.map { locale in
            AppleLanguage(
                identifier: locale.identifier,
                displayName: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier,
                locale: locale,
                resourceState: state
            )
        }
        .sorted { $0.displayName < $1.displayName }
    }

    private func makeLanguages(locales: [Locale],
                               state: (Locale) -> AppleLanguageResourceState) -> [AppleLanguage] {
        locales.map { locale in
            AppleLanguage(
                identifier: locale.identifier,
                displayName: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier,
                locale: locale,
                resourceState: state(locale)
            )
        }
        .sorted { $0.displayName < $1.displayName }
    }
}
