import Foundation

// MARK: - 翻译 Provider 抽象层
//
// 统一翻译提供方接口（渐进式重构第二步，ASR 部分不动）：
//
//   AppState（句尾翻译 / 批量翻译）
//         ↓
//   TranslationManager（按 TranslationMode 分发）
//         ↓
//   TranslationProvider（协议）
//         ↓
//   LMStudioProvider  包装本地 OpenAI 兼容服务（LM Studio / Ollama / llama.cpp）
//   OnlineAPIProvider 包装在线 OpenAI 兼容 API
//
// 底层实现仍为 TranslationService（未改动），输入输出数据结构
// （[String] 译文、TranslationError）与重构前完全一致。

/// 翻译提供方标识。
enum TranslationProviderKind: String, Sendable {
    /// 本地模型服务（LM Studio / Ollama / llama.cpp server）。
    case lmStudio
    /// 在线 OpenAI 兼容 API。
    case onlineAPI
    /// 系统翻译框架（macOS 15+；低版本报告不可用）。
    case apple
}

/// 连接测试结果（testConnection() 返回值）。
enum TranslationConnectionStatus: Sendable, Equatable {
    /// 缺少必要配置（在线模式未配置端点/密钥等）。
    case notConfigured(String)
    /// 连接成功；本地模式附探测到的模型名，在线模式为 nil。
    case connected(model: String?)
    /// 连接失败（附原因）。
    case failed(String)
}

/// Provider 状态快照（status() 返回值）。
enum TranslationProviderStatus: Sendable, Equatable {
    /// 未配置，等待自动探测/配置（本地模式未填端点）。
    case idle
    /// 已就绪（附配置摘要）。
    case ready(description: String)
    /// 不可用（附原因）。
    case unavailable(String)
}

/// 统一翻译请求（TranslationRequest）。
struct TranslationRequest: Sendable {
    /// 待翻译文本行（批量场景；单句时长度为 1）。
    let texts: [String]
    /// 源语言（nil/空 = 自动检测）。
    var sourceLanguage: String? = nil
    /// 目标语言 locale id（如 "en"、"zh-Hans"）。
    var targetLanguage: String
    /// 同会话已译段落（术语/风格一致性参考）。
    var previousTranslations: [(original: String, translated: String)] = []

    /// 便捷：单句文本。
    var text: String { texts.joined() }

    init(text: String, sourceLanguage: String? = nil,
         targetLanguage: String,
         previousTranslations: [(original: String, translated: String)] = []) {
        self.texts = [text]
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.previousTranslations = previousTranslations
    }

    init(texts: [String], sourceLanguage: String? = nil,
         targetLanguage: String,
         previousTranslations: [(original: String, translated: String)] = []) {
        self.texts = texts
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.previousTranslations = previousTranslations
    }
}

/// 统一翻译输出（TranslationResult）。
struct TranslationResult: Sendable {
    /// 与输入等长的译文数组（不足部分以空串补齐）。
    let texts: [String]
    /// 检测/指定的源语言（可选）。
    var sourceLanguage: String? = nil
    /// 目标语言。
    var targetLanguage: String? = nil
    /// 置信度（可选；Apple 翻译可提供）。
    var confidence: Float? = nil
    /// 便捷：合并文本（多行场景拼接）。
    var text: String { texts.joined() }
    /// 便捷：语言（源语言优先）。
    var language: String? { sourceLanguage ?? targetLanguage }
}

/// 统一翻译 Provider 接口（统一输入 TranslationRequest / 输出 TranslationResult）。
protocol TranslationProvider: Sendable {
    /// 提供方标识。
    var kind: TranslationProviderKind { get }

    /// 翻译（输入输出统一结构）。
    func translate(_ request: TranslationRequest) async throws -> TranslationResult

    /// 流式翻译（单句）：逐 token 回调增量，返回完整译文。
    /// 默认回退非流式（一次性回调完整结果）。
    func translateStreaming(_ request: TranslationRequest,
                            onDelta: @escaping @Sendable (String) -> Void) async throws -> TranslationResult

    /// 连接测试：验证配置可用性与端到端连通（不发真实字幕翻译请求）。
    func testConnection() async -> TranslationConnectionStatus

    /// 当前配置状态快照。
    func status() async -> TranslationProviderStatus
}


extension TranslationProvider {
    func translateStreaming(_ request: TranslationRequest,
                            onDelta: @escaping @Sendable (String) -> Void) async throws -> TranslationResult {
        let result = try await translate(request)
        onDelta(result.texts.joined())
        return result
    }
}
