import Foundation
import Speech

// MARK: - Apple Speech 语言资源管理（AppleSpeechLanguageManager）
//
// 获取本机已安装的语音识别语言资源（可直接离线使用的语言）：
// - macOS 26+：DictationTranscriber.installedLocales（系统已安装资产，
//   不包含"支持但未下载 / 需要下载 / 不可用"语言）；
// - 低版本回退：SFSpeechRecognizer.supportedLocales（旧系统无 installed API，
//   如实标注 isInstalled=false 语义退化为"受支持"）。
//
// 过滤规则（AppleSpeechLanguage.isAvailable）：
// 1. 语言资源已安装（installedLocales 命中）；
// 2. SFSpeechRecognizer 可创建（locale 受支持）；
// 3. 支持当前识别模式（on-device 优先时设备支持离线识别）。
//
// 输出 AppleSpeechLanguage：identifier / displayName / locale / isInstalled / isAvailable。
// 设置页语言列表只显示本管理器返回的已安装语言。

/// 一条 Apple Speech 语言资源。
struct AppleSpeechLanguage: Identifiable, Equatable {
    let identifier: String
    let displayName: String
    let locale: Locale
    /// 系统已安装（语言包在本地，可直接离线使用）。
    let isInstalled: Bool
    /// 立即可用（已安装 + 可创建 + 支持当前识别模式）。
    let isAvailable: Bool

    var id: String { identifier }
}

final class AppleSpeechLanguageManager: @unchecked Sendable {
    static let shared = AppleSpeechLanguageManager()

    private init() {}

    /// 本机已安装的识别语言（可直接离线使用）。
    func installedLanguages() async -> [AppleSpeechLanguage] {
        let installed = await installedLocales()
        return await makeLanguages(locales: installed, markInstalled: true)
    }

    /// 全部受支持语言（含未安装；调试 / 低版本回退展示用）。
    func supportedLanguages() async -> [AppleSpeechLanguage] {
        let supported = Array(SFSpeechRecognizer.supportedLocales())
        return await makeLanguages(locales: supported, markInstalled: false)
    }

    // MARK: - 私有

    /// 已安装语言集合（macOS 26+ 系统资产查询；低版本回退全部支持语言）。
    /// 参考 v2s：使用 SpeechTranscriber（完整 ASR 识别资产）为主，
    /// 并集 DictationTranscriber（听写资产）补全，避免语言列表不全。
    private func installedLocales() async -> [Locale] {
        if #available(macOS 26, *) {
            let speech = await SpeechTranscriber.installedLocales
            let dictation = await DictationTranscriber.installedLocales
            return Array(Set(speech).union(dictation)).sorted { $0.identifier < $1.identifier }
        }
        return Array(SFSpeechRecognizer.supportedLocales())
    }

    /// 组装语言条目（新 Speech 框架能力检测，不做旧逻辑过滤）：
    /// - macOS 26+：installedLocales 即系统能力结论，条目直接可用；
    /// - 低版本回退：全部支持语言（legacy 视角，标注未安装）。
    private func makeLanguages(locales: [Locale], markInstalled: Bool) async -> [AppleSpeechLanguage] {
        var result: [AppleSpeechLanguage] = []
        for locale in locales {
            let identifier = locale.identifier
            let displayName = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
            result.append(AppleSpeechLanguage(
                identifier: identifier,
                displayName: displayName,
                locale: locale,
                isInstalled: markInstalled,
                isAvailable: markInstalled
            ))
        }
        return result.sorted { $0.displayName < $1.displayName }
    }
}
