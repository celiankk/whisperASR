import Foundation
import Translation

// MARK: - Apple Translation Engine（AppleTranslationEngine）
//
// macOS 系统翻译引擎（Translation Framework），独立于 Speech：
//
//   ASR Final Result → TranslationManager → AppleTranslationEngine → TranslationResult
//
// 能力检测（运行时，非硬编码版本）：
// - macOS 26+：程序化 TranslationSession(installedSource:target:) 可创建 → 真实翻译；
// - 更低版本：框架仅 SwiftUI environment 注入接口 → 如实报告不可用。
// - 语言资源：LanguageAvailability.status(for:to:)（installed / supported / unsupported）。
//
// 状态：Idle / Initializing / Available / Need Resource / Unavailable / Error。
// AppleTranslationDebug：Session 状态 / 语言状态 / 翻译耗时 / 错误信息。

final class AppleTranslationEngine: @unchecked Sendable {
    private(set) var state: AppleTranslationEngineState = .idle

    // MARK: - 调试统计（AppleTranslationDebug）

    private(set) var debug = AppleTranslationDebug()

    /// 系统翻译框架是否可用（macOS 15+ 框架存在 + 系统支持）。
    var isSystemSupported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    /// 程序化会话是否可创建（macOS 26+）。
    var isSessionAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// 目标语言资源状态（installed / supported / unsupported）。
    /// 多候选源语言检测（系统语言 + en）——固定 en 时目标语言为 en
    /// 会误报 unsupported（系统不支持同语言翻译，但中→英是合理的）。
    func languageStatus(for target: String) async -> AppleTranslationLanguageState {
        await AppleTranslationLanguageProbe.state(for: target)
    }

    /// 翻译文本（源语言自动检测；目标语言指定）。
    /// 返回统一 TranslationResult（texts / sourceLanguage / targetLanguage / confidence）。
    func translate(texts: [String],
                   sourceLanguage: String?,
                   targetLanguage: String) async throws -> TranslationResult {
        guard !texts.isEmpty else {
            return TranslationResult(texts: [], targetLanguage: targetLanguage)
        }
        // 与 OpenAI 兼容路径一致：输入 NFKC 归一化（全半角混排清洗）。
        let texts = texts.map(TranslationService.normalizeForTranslation)
        guard #available(macOS 26, *) else {
            state = .unavailable
            throw TranslationError.unavailable
        }
        state = .initializing
        let begin = Date()
        debug.sessionCreated = true
        debug.translateCount += 1
        let target = Locale.Language(identifier: targetLanguage)
        // 源语言：显式指定优先，否则自动检测。
        let source: Locale.Language
        if let sourceLanguage, !sourceLanguage.isEmpty {
            source = Locale.Language(identifier: sourceLanguage)
        } else {
            let detected = TranslationService.detectSourceLanguage(texts)
            source = Self.sourceLocale(for: detected)
        }
        debug.languageStatus = source.minimalIdentifier
        let session = TranslationSession(installedSource: source, target: target)
        let requests = texts.map { TranslationSession.Request(sourceText: $0) }
        do {
            let result = try await performTranslation(session: session, requests: requests,
                                                      source: source, target: target, begin: begin)
            state = .available
            return result
        } catch {
            // 瞬时失败（冷启动 / 翻译模型加载中）自动重试一次，
            // 避免计入 TranslationManager 的 3 连败降级。
            // 重试必须新建 session：失败的 session 状态可能已失效，
            // 复用大概率再次抛同一个错误。
            AppLogger.shared.log(.translation, "AppleTranslationDebug: retry after error \(error.localizedDescription)")
            let retrySession = TranslationSession(installedSource: source, target: target)
            do {
                let result = try await performTranslation(session: retrySession, requests: requests,
                                                          source: source, target: target, begin: begin)
                state = .available
                return result
            } catch {
                state = .error
                debug.lastError = error.localizedDescription
                AppLogger.shared.log(.translation, "AppleTranslationDebug: error \(error.localizedDescription) "
                    + "source=\(source.minimalIdentifier) target=\(target.minimalIdentifier)")
                throw TranslationError.apiFailed(error.localizedDescription)
            }
        }
    }

    /// 单次翻译调用（成功路径共用；失败由调用方重试）。
    @available(macOS 26, *)
    private func performTranslation(session: TranslationSession,
                                    requests: [TranslationSession.Request],
                                    source: Locale.Language,
                                    target: Locale.Language,
                                    begin: Date) async throws -> TranslationResult {
        let responses = try await session.translations(from: requests)
        let translated = responses.map(\.targetText)
        debug.lastTranslateDuration = Date().timeIntervalSince(begin)
        debug.lastError = nil
        AppLogger.shared.log(.translation, "AppleTranslationDebug: translate \(translated.count) lines "
            + "in \(Int(debug.lastTranslateDuration * 1000))ms source=\(source.minimalIdentifier) "
            + "target=\(target.minimalIdentifier)")
        return TranslationResult(
            texts: translated,
            sourceLanguage: source.minimalIdentifier,
            targetLanguage: target.minimalIdentifier,
            confidence: nil
        )
    }

    /// SourceLanguage → Locale.Language（翻译框架语言标识）。
    private static func sourceLocale(for source: SourceLanguage) -> Locale.Language {
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
