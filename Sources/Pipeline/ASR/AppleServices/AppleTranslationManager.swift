import Foundation
import Translation

// MARK: - Apple Translation Manager（AppleTranslationManager）
//
// Apple 翻译的 TranslationProvider 适配层（统一注册到 TranslationManager，
// 按翻译方式分发，不绕过 Manager）：
//
//   ASR Final Result → TranslationManager → AppleTranslationManager
//                                                  ↓
//   AppleTranslationEngine（TranslationSession(installedSource:target:)）
//                                                  ↓
//   TranslationResult（统一输出：texts / sourceLanguage / targetLanguage）
//
// 能力检测（运行时）：
// - macOS 26+：程序化 TranslationSession 可用 → 真实翻译；
// - 更低版本：如实报告不可用（不影响其他 Provider）。
// 状态与语言资源由 AppleTranslationStatus 统一检测（View 只读快照）。

struct AppleTranslationManager: TranslationProvider {
    var kind: TranslationProviderKind { .apple }

    private let engine = AppleTranslationEngine()

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await engine.translate(texts: request.texts,
                                   sourceLanguage: request.sourceLanguage,
                                   targetLanguage: request.targetLanguage)
    }

    func testConnection() async -> TranslationConnectionStatus {
        let status = AppleTranslationStatus.shared
        await status.refresh()
        switch status.state {
        case .available:
            return .connected(model: nil)
        case .needResource:
            return .notConfigured("缺少目标语言资源（需要下载语言包）")
        case .unavailable:
            return .notConfigured("Apple 翻译在当前系统不可用")
        case .error:
            return .failed("Apple 翻译初始化失败")
        case .idle, .initializing:
            return .failed("Apple 翻译状态未知")
        }
    }

    func status() async -> TranslationProviderStatus {
        let status = AppleTranslationStatus.shared
        await status.refresh()
        switch status.state {
        case .available:
            return .ready(description: "Apple 翻译可用（\(status.targetLanguage)）")
        case .needResource:
            return .unavailable("需要语言资源：\(status.targetLanguage)")
        case .unavailable:
            return .unavailable("Apple 翻译不可用")
        case .error:
            return .unavailable("Apple 翻译初始化失败")
        case .idle, .initializing:
            return .unavailable("Apple 翻译状态未知")
        }
    }
}
