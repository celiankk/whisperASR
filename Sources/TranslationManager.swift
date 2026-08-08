import Foundation

// MARK: - 翻译管理器（TranslationManager）
//
// 按当前 TranslationMode 分发到对应 TranslationProvider：
//
//   AppState / SubtitleEngine 链路
//         ↓
//   TranslationManager
//         ↓
//   TranslationProvider
//         ↓
//   LMStudioProvider（local: true） / OnlineAPIProvider（local: false）
//
// 取代 1.4 的 TranslationEngineFactory；句尾翻译、3 连败降级、
// 10s 超时兜底等上层逻辑全部保持不变。

enum TranslationManager {
    static let lmStudio = LMStudioProvider()
    static let onlineAPI = OnlineAPIProvider()

    /// 按翻译方式返回对应 Provider。
    /// 注意：`.off` 时返回在线 Provider，与原 TranslationEngineFactory
    /// （`.off` → local=false）行为完全一致——实时句尾翻译路径在 AppState
    /// 已先按 `.off` 短路，此映射仅服务于批量翻译等不检查模式的路径。
    static func provider(for mode: TranslationMode) -> TranslationProvider {
        switch mode {
        case .off, .onlineAPI:
            return onlineAPI
        case .localModel:
            return lmStudio
        }
    }

    /// 便捷转发：按当前保存的翻译方式翻译。
    static func translate(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = []
    ) async throws -> [String] {
        try await provider(for: TranslationMode.current).translate(
            segmentTexts: segmentTexts,
            targetLanguage: targetLanguage,
            previousTranslations: previousTranslations
        )
    }

    /// 便捷转发：按指定方式测试连接。
    static func testConnection(for mode: TranslationMode) async -> TranslationConnectionStatus {
        await provider(for: mode).testConnection()
    }

    /// 便捷转发：按指定方式查询状态。
    static func status(for mode: TranslationMode) async -> TranslationProviderStatus {
        await provider(for: mode).status()
    }
}
