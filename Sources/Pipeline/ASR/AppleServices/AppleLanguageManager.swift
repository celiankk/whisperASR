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

    /// 本机已安装的识别语言（可直接离线使用）。
    func installedLanguages() async -> [AppleLanguage] {
        let installed = await installedLocales()
        return makeLanguages(locales: installed, state: .installed)
    }

    /// 全部受支持语言（含未安装；Available / Need Download）。
    func supportedLanguages() async -> [AppleLanguage] {
        guard #available(macOS 26, *) else { return [] }
        let supported = await SpeechTranscriber.supportedLocales
        let installedIDs = Set(await installedLocales().map(\.identifier))
        return makeLanguages(locales: supported) { locale in
            installedIDs.contains(locale.identifier) ? .installed : .needDownload
        }
    }

    /// 支持但未安装的语言（Need Download；设置页禁用展示）。
    func unavailableLanguages() async -> [AppleLanguage] {
        guard #available(macOS 26, *) else { return [] }
        let supported = await SpeechTranscriber.supportedLocales
        let installedIDs = Set(await installedLocales().map(\.identifier))
        let missing = supported.filter { !installedIDs.contains($0.identifier) }
        return makeLanguages(locales: missing, state: .needDownload)
    }

    /// 当前语言资源状态（Installed / Need Download / Unavailable）。
    func resourceState(for localeIdentifier: String) async -> AppleLanguageResourceState {
        let installed = await installedLanguages()
        if installed.contains(where: { $0.identifier == localeIdentifier }) {
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
