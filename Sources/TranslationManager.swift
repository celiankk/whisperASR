import Foundation

// MARK: - 翻译管理器（TranslationManager）
//
// AppState 拆分的一部分：翻译队列、Translation Provider 调用、API 请求管理。
// 由 AppRuntimeManager 持有；AppState 只保留翻译相关 UI 状态并委托本管理器。
//
// 职责：
// - Provider 分发：按 TranslationMode 路由到 LMStudioProvider / OnlineAPIProvider；
// - 实时句尾翻译：有界并发队列（上限 8）+ 10s 超时兜底 + 3 连败自动降级
//   （仅识别模式），历史记录（原文/译文/语言）在此单一收口；
// - 批量翻译：历史记录整段翻译（batch 循环、瞬时错误重试分类）；
// - 停止/退出：resetForStop() / cancelAll() 取消全部在途请求。
//
// 保持 1.4 行为：句尾翻译逻辑、超时回退、降级规则完全不变。
// 隔离策略：类本身非隔离（便于 AppRuntimeManager / ASRManager
// 同步调用 reset/cancel），涉及 UI 状态的方法单独标注 @MainActor。

final class TranslationManager {
    /// 由 AppRuntimeManager 注入（读取翻译模式/暂停状态、展示 toast）。
    weak var appState: AppState?

    // MARK: - Provider 分发（无状态，原 enum 接口保留）

    private static let local = LocalTranslationProvider()
    private static let online = ChatCompletionProvider()
    private static let apple = AppleTranslationProvider()

    /// 按翻译方式返回对应 Provider。
    /// 注意：`.off` 时返回在线 Provider，与原 TranslationEngineFactory
    /// （`.off` → local=false）行为完全一致——实时句尾翻译路径在调用方
    /// 已先按 `.off` 短路，此映射仅服务于批量翻译等不检查模式的路径。
    static func provider(for mode: TranslationMode) -> TranslationProvider {
        switch mode {
        case .off, .onlineAPI:
            return online
        case .localModel:
            return local
        case .apple:
            return apple
        }
    }

    /// 便捷转发：按当前保存的翻译方式翻译。
    static func translate(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = []
    ) async throws -> TranslationResult {
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

    // MARK: - 实时句尾翻译状态

    /// 在途句数，超上限丢弃最新（显示原文兜底）。
    /// 有界并发：每句独立请求（本地/在线服务自带队列与重试），不做串行链——
    /// 串行会让后到的译文错过字幕状态机窗口被丢弃，且体感翻译明显变慢。
    private(set) var sentenceTranslationPending = 0
    private static let maxPendingSentenceTranslations = 8

    /// 连续失败计数（≥3 自动降级为“仅识别模式”）。
    private(set) var translationFailureCount = 0
    /// 认证/不可用错误驱动的自动暂停（区别于用户手动暂停）。
    private(set) var translationAuthPaused = false
    /// 降级状态由本管理器回写 AppState.translationUnavailable（UI 绑定）。

    /// 批量翻译任务句柄（取消/退出时统一取消）。
    private var translateTask: Task<Void, Never>?

    // MARK: - 实时句尾翻译

    /// 整句翻译（字幕层检测到一句结束后调用，一次一句、单飞）：
    /// 所有语言统一进入 TranslationProvider；失败返回 nil（显示原文），
    /// 连续失败 3 次自动降级为“仅识别模式”。
    @MainActor
    func translateSentence(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let appState,
              appState.translationMode != .off,
              !appState.liveTranslationPaused,
              !translationAuthPaused else {
            return nil
        }
        let targetLang = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
        guard !targetLang.isEmpty else { return nil }

        let provider = Self.provider(for: appState.translationMode)
        do {
            let result = try await provider.translate(
                segmentTexts: [trimmed],
                targetLanguage: targetLang,
                previousTranslations: []
            )
            translationFailureCount = 0
            appState.setTranslationUnavailable(false)
            return result.texts.first
        } catch is CancellationError {
            // 取消（超时兜底 / 暂停 / 停止）不是服务故障：不计入三连失败。
            return nil
        } catch {
            ErrorManager.shared.report(.api, error, context: "translateSentence")
            translationFailureCount += 1
            if translationFailureCount >= 3 {
                appState.setTranslationUnavailable(true)
                translationAuthPaused = true
                appState.showToast("本地翻译服务不可用，已切换到仅识别模式")
            }
            return nil
        }
    }

    /// 整句翻译统一入口（桥接层调用）：有界并发 + 10s 超时兜底 + 队列上限。
    /// 历史记录（时间/原文/翻译/语言）在此单一收口。
    @MainActor
    func requestSentenceTranslation(_ text: String) async -> String? {
        guard sentenceTranslationPending < Self.maxPendingSentenceTranslations else {
            AppLogger.shared.log(.translation, "Sentence queue full, drop: \(text.prefix(24))…")
            SubtitleHistoryManager.shared.record(
                original: text, translation: nil, language: LanguageDetector.detect(text).rawValue
            )
            return nil
        }
        sentenceTranslationPending += 1
        defer { sentenceTranslationPending -= 1 }
        let result: String?
        do {
            result = try await Self.withTimeout(seconds: 10) {
                await self.translateSentence(text)
            }
        } catch is CancellationError {
            result = nil
        } catch {
            // 超时 = 服务慢（≠ 服务不可用）：只记日志，不计入三连失败降级。
            ErrorManager.shared.report(.network, error, context: "sentence translation timeout")
            result = nil
        }
        // 历史记录独立存储（容量上限 200），与实时字幕状态分离。
        SubtitleHistoryManager.shared.record(
            original: text, translation: result, language: LanguageDetector.detect(text).rawValue
        )
        return result
    }

    /// 用户手动暂停时重置在途计数（AppState.setLiveTranslationPaused 委托）。
    func resetPending() {
        sentenceTranslationPending = 0
    }

    // MARK: - 批量翻译（历史记录整段）

    /// 整段批量翻译：分批（20 句）翻译 + 上下文（前 2 句）参考；
    /// 非瞬时错误（认证/无效端点/本地模型未检测）停止整段并 toast 一次，
    /// 瞬时错误跳过该批继续，最后提示不完整结果。
    @MainActor
    func translate(item: TranscriptionItem, targetLanguage: String) {
        guard !item.segments.isEmpty, !item.isTranslating else { return }
        item.isTranslating = true
        item.translatedSegments = Array(repeating: "", count: item.segments.count)
        item.translationLanguage = targetLanguage

        // @MainActor: `item` is observed by SwiftUI, so every mutation below must
        // land on the main actor; only the translation API calls suspend off it.
        translateTask?.cancel()
        translateTask = Task { @MainActor in
            let texts = item.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }

            let batchSize = 20
            var transientFailures = 0

            batchLoop: for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, texts.count)
                let batch = Array(texts[batchStart..<batchEnd])

                let contextStart = max(0, batchStart - 2)
                let contextPairs: [(original: String, translated: String)] = (contextStart..<batchStart).compactMap { i in
                    guard !texts[i].isEmpty, !item.translatedSegments[i].isEmpty else { return nil }
                    return (original: texts[i], translated: item.translatedSegments[i])
                }

                let provider = TranslationManager.provider(for: TranslationMode.current)
                do {
                    let translations = try await provider.translate(
                        segmentTexts: batch,
                        targetLanguage: targetLanguage,
                        previousTranslations: contextPairs
                    )
                    for (offset, translation) in translations.texts.enumerated() {
                        item.translatedSegments[batchStart + offset] = translation
                    }
                } catch let err as TranslationError {
                    print("[Translation] batch error: \(err)")
                    switch err {
                    case .authFailed, .invalidEndpoint, .localModelNotDetected, .unavailable:
                        // Not retriable — stop hammering the API and report it once.
                        self.appState?.showToast(err.errorDescription ?? "Translation failed")
                        break batchLoop
                    default:
                        transientFailures += 1
                    }
                } catch {
                    print("[Translation] batch error: \(error)")
                    transientFailures += 1
                }
            }

            // Some batches failed transiently (network/server/rate-limit) but we
            // kept going; let the user know the result is incomplete.
            if transientFailures > 0 {
                self.appState?.showToast("Translation incomplete — \(transientFailures) section\(transientFailures == 1 ? "" : "s") couldn't be translated. Check your network or API settings.")
            }

            item.isTranslating = false
            self.appState?.history.save(item)
        }
    }

    // MARK: - 停止 / 退出

    /// 停止实时会话时重置翻译状态（在途计数、失败计数、认证暂停）。
    func resetForStop() {
        sentenceTranslationPending = 0
        translationFailureCount = 0
        translationAuthPaused = false
    }

    /// 仅清零失败计数（自动恢复用；保留认证暂停状态，避免循环恢复）。
    func clearFailureCount() {
        translationFailureCount = 0
    }

    /// 取消全部在途翻译任务（应用退出 / 会话停止）。
    func cancelAll() {
        translateTask?.cancel()
        translateTask = nil
        sentenceTranslationPending = 0
    }

    // MARK: - Timeout helper

    private struct TimeoutError: Error {}

    /// Run `operation` with a timeout. If it doesn't complete within `seconds`, throws TimeoutError.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
