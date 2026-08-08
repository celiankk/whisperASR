import Foundation

/// OnlineAPIProvider：在线 OpenAI 兼容 API 适配层。
///
/// 包装 TranslationService 的在线模式（`local: false`）：
/// - 端点：用户配置的 translationEndpoint，为空时默认 api.openai.com；
/// - 密钥：translationAPIKey（空则不发送 Authorization 头）；
/// - 模型：translationModel，为空回退 "gpt-4o-mini"。
/// 内部实现未改动，仅收敛到统一 TranslationProvider 接口。
struct OnlineAPIProvider: TranslationProvider {
    var kind: TranslationProviderKind { .onlineAPI }

    func translate(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)]
    ) async throws -> [String] {
        try await TranslationService.translateSegmentsWithOpenAI(
            segmentTexts: segmentTexts,
            targetLanguage: targetLanguage,
            previousTranslations: previousTranslations,
            local: false
        )
    }

    /// 与设置页「重新连接」一致：先检查配置，再发一条真实翻译请求验证
    /// 端到端连通（目标语言取当前设置，缺省 en）。
    func testConnection() async -> TranslationConnectionStatus {
        guard TranslationService.isAPIConfigured else {
            return .notConfigured("未配置 API 端点 / Key")
        }
        let lang = (UserDefaults.standard.string(forKey: "targetLanguage") ?? "").isEmpty
            ? "en" : UserDefaults.standard.string(forKey: "targetLanguage")!
        do {
            let translations = try await translate(
                segmentTexts: ["Hello, world."],
                targetLanguage: lang,
                previousTranslations: []
            )
            let sample = translations.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if sample.isEmpty {
                return .failed("空响应")
            }
            return .connected(model: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func status() async -> TranslationProviderStatus {
        guard TranslationService.isAPIConfigured else {
            return .unavailable("未配置 API 端点 / Key")
        }
        let endpoint = (UserDefaults.standard.string(forKey: TranslationService.ConfigKeys.endpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (UserDefaults.standard.string(forKey: TranslationService.ConfigKeys.model) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = endpoint.isEmpty ? "默认 OpenAI 端点" : "endpoint=\(endpoint)"
        if !model.isEmpty {
            return .ready(description: "\(summary), model=\(model)")
        }
        return .ready(description: summary)
    }
}
