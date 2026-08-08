import Foundation
import Translation

// MARK: - Apple Translation Provider（AppleTranslationProvider）
//
// 基于系统 Translation 框架的翻译适配层，实现 TranslationProvider 协议。
//
// 能力检测（非硬编码版本判断，运行时决定）：
// - #available 分支 + LanguageAvailability 语言资源检测；
// - macOS 26+：程序化 TranslationSession（installedSource:target:）可创建，
//   实现真实翻译（源语言自动检测）；
// - macOS 15-25：框架仅暴露 SwiftUI environment 注入接口，服务层不可创建
//   会话 → 如实抛 .unavailable；
// - macOS 14 及以下：框架不存在 → 不可用。
//
// 状态与语言资源由 AppleServiceStatusManager 统一检测（View 只读快照）。
// 失败抛给上层 catch——不影响其他 Provider，默认关闭。

struct AppleTranslationProvider: TranslationProvider {
    var kind: TranslationProviderKind { .apple }

    func translate(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)]
    ) async throws -> TranslationResult {
        guard !segmentTexts.isEmpty else { return TranslationResult(texts: []) }
        if #available(macOS 26, *) {
            let texts = try await Self.translateNative(segmentTexts: segmentTexts,
                                                       targetLanguage: targetLanguage)
            return TranslationResult(texts: texts)
        }
        // 15-25：框架仅 SwiftUI environment 注入接口，服务层不可用。
        throw TranslationError.unavailable
    }

    func testConnection() async -> TranslationConnectionStatus {
        let manager = AppleServiceStatusManager.shared
        await manager.refresh()
        switch manager.translationState {
        case .available:
            return .connected(model: nil)
        case .needLanguageResource:
            return .notConfigured("缺少目标语言资源（需要下载语言包）")
        case .unavailable:
            return .notConfigured("Apple 翻译在当前系统不可用")
        case .error:
            return .failed("Apple 翻译初始化失败")
        }
    }

    func status() async -> TranslationProviderStatus {
        let manager = AppleServiceStatusManager.shared
        await manager.refresh()
        switch manager.translationState {
        case .available:
            return .ready(description: "Apple 翻译可用（\(manager.translationTargetLanguage)）")
        case .needLanguageResource:
            return .unavailable("需要语言资源：\(manager.translationTargetLanguage)")
        case .unavailable:
            return .unavailable("Apple 翻译不可用")
        case .error:
            return .unavailable("Apple 翻译初始化失败")
        }
    }

    // MARK: - macOS 26+ 原生翻译

    @available(macOS 26, *)
    private static func translateNative(segmentTexts: [String],
                                        targetLanguage: String) async throws -> [String] {
        let target = Locale.Language(identifier: targetLanguage)
        // 源语言自动检测（与字幕显示同策略）。
        let source = sourceLanguageLocale(for: TranslationService.detectSourceLanguage(segmentTexts))
        let session = TranslationSession(installedSource: source, target: target)
        let requests = segmentTexts.map { TranslationSession.Request(sourceText: $0) }
        do {
            let responses = try await session.translations(from: requests)
            return responses.map(\.targetText)
        } catch {
            throw TranslationError.apiFailed(error.localizedDescription)
        }
    }

    /// SourceLanguage → Locale.Language（翻译框架语言标识）。
    @available(macOS 26, *)
    private static func sourceLanguageLocale(for source: SourceLanguage) -> Locale.Language {
        switch source {
        case .zhCN: return Locale.Language(identifier: "zh-Hans")
        case .zhTW, .zhHK: return Locale.Language(identifier: "zh-Hant")
        case .en: return Locale.Language(identifier: "en")
        case .ja: return Locale.Language(identifier: "ja")
        case .ko: return Locale.Language(identifier: "ko")
        case .ru: return Locale.Language(identifier: "ru")
        case .other: return Locale.Language(identifier: "en")
        }
    }
}
