import Foundation

/// ChatCompletionProvider：在线 OpenAI 兼容 API 适配层
///（POST {base}/chat/completions）。
///
/// 包装 TranslationService 的在线模式（`local: false`）：
/// - 端点：用户配置的 translationEndpoint，为空时默认 api.openai.com；
/// - 密钥：translationAPIKey（空则不发送 Authorization 头）；
/// - 模型：translationModel，为空回退 "gpt-4o-mini"。
/// 内部实现未改动，仅收敛到统一 TranslationProvider 接口。
struct ChatCompletionProvider: TranslationProvider {
    var kind: TranslationProviderKind { .onlineAPI }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let texts = try await TranslationService.translateSegmentsWithOpenAI(
            segmentTexts: request.texts,
            targetLanguage: request.targetLanguage,
            previousTranslations: request.previousTranslations,
            local: false
        )
        return TranslationResult(texts: texts,
                                 targetLanguage: request.targetLanguage)
    }

    /// 流式（单句）：SSE 逐 token 喂 onDelta，译文逐字上屏。
    func translateStreaming(_ request: TranslationRequest,
                            onDelta: @escaping @Sendable (String) -> Void) async throws -> TranslationResult {
        let local = UserDefaults.standard.string(forKey: "translationMode") == TranslationMode.localModel.rawValue
        let text = try await TranslationService.translateStreaming(
            segmentText: request.texts.joined(separator: "\n"),
            targetLanguage: request.targetLanguage,
            previousTranslations: request.previousTranslations,
            local: local,
            onDelta: onDelta)
        return TranslationResult(texts: [text], targetLanguage: request.targetLanguage)
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
                TranslationRequest(text: "Hello, world.", targetLanguage: lang))
            let sample = translations.texts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
