import Foundation

/// LocalTranslationProvider：本地 OpenAI 兼容服务（LM Studio / Ollama / llama.cpp
/// server）适配层。
///
/// 包装 TranslationService 的本地模式（`local: true`）：
/// - 端点解析：用户配置优先，否则依次探测 127.0.0.1:1234/11434/8080；
/// - 模型名：未配置时自动取服务第一个模型（取不到抛 localModelNotDetected）。
/// 内部实现未改动，仅收敛到统一 TranslationProvider 接口。
struct LocalTranslationProvider: TranslationProvider {
    var kind: TranslationProviderKind { .lmStudio }

    func translate(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)]
    ) async throws -> TranslationResult {
        let texts = try await TranslationService.translateSegmentsWithOpenAI(
            segmentTexts: segmentTexts,
            targetLanguage: targetLanguage,
            previousTranslations: previousTranslations,
            local: true
        )
        return TranslationResult(texts: texts)
    }

    /// 与设置页「检测 API 状态」的本地分支一致：解析端点并探测模型列表，
    /// 不发真实翻译请求。
    func testConnection() async -> TranslationConnectionStatus {
        let endpoint = await TranslationService.resolveLocalEndpoint()
        if let model = await TranslationService.fetchFirstLocalModel(baseURL: endpoint) {
            return .connected(model: model)
        }
        return .failed("本地服务未启动（LM Studio / Ollama / llama.cpp）")
    }

    func status() async -> TranslationProviderStatus {
        let configured = (UserDefaults.standard.string(forKey: TranslationService.ConfigKeys.endpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return .ready(description: "endpoint=\(TranslationService.normalizedBaseURL(configured))")
        }
        // 未填端点：运行时自动探测本地候选端口（1234/11434/8080）。
        return .idle
    }
}
