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

/// 统一翻译输出（TranslationResult）。
struct TranslationResult: Sendable {
    /// 与输入等长的译文数组（不足部分以空串补齐）。
    let texts: [String]
    /// 检测/指定的源语言（可选）。
    var sourceLanguage: String? = nil
}

/// 统一翻译 Provider 接口（统一输出 TranslationResult）。
protocol TranslationProvider: Sendable {
    /// 提供方标识。
    var kind: TranslationProviderKind { get }

    /// 翻译一批字幕文本（输入输出数据结构与 1.4 一致，输出统一为 TranslationResult）。
    /// - Parameters:
    ///   - segmentTexts: 待翻译的原文行数组。
    ///   - targetLanguage: 目标语言 locale id（如 "en"、"zh-Hans"）。
    ///   - previousTranslations: 同会话已译段落（术语/风格一致性参考）。
    /// - Returns: 与 segmentTexts 等长的译文数组（不足部分以空串补齐）。
    func translate(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)]
    ) async throws -> TranslationResult

    /// 连接测试：验证配置可用性与端到端连通（不发真实字幕翻译请求）。
    func testConnection() async -> TranslationConnectionStatus

    /// 当前配置状态快照。
    func status() async -> TranslationProviderStatus
}
