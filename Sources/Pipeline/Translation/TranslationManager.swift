import Foundation
import os

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
    private static let apple = AppleTranslationManager()
    private static let googleV1 = FreeWebTranslationProvider(channel: .googleV1)
    private static let googleV2 = FreeWebTranslationProvider(channel: .googleV2)
    private static let microsoft = FreeWebTranslationProvider(channel: .microsoft)

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
        case .googleV1:
            return googleV1
        case .googleV2:
            return googleV2
        case .microsoft:
            return microsoft
        }
    }

    /// 便捷转发：按当前保存的翻译方式翻译。
    static func translate(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = []
    ) async throws -> TranslationResult {
        try await provider(for: TranslationMode.current).translate(
            TranslationRequest(texts: segmentTexts,
                               targetLanguage: targetLanguage,
                               previousTranslations: previousTranslations))
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

    /// 有界并发的在途计数 + 失败/认证暂停状态。
    ///
    /// 这些字段的**写入点跨越隔离边界**：翻译入口是 @MainActor，而退出/停录
    /// 路径的 `resetForStop()/resetPending()/clearFailureCount()/cancelAll()`
    /// 是非隔离方法（AppRuntimeManager.shutdown / ASRManager.startLive）。
    /// 此前无任何同步原语，属真实跨线程数据竞争（Swift 6 严格并发会报错）；
    /// 现全部经 OSAllocatedUnfairLock 保护的快照读写。
    private struct LiveTranslationState {
        var pending = 0
        var failureCount = 0
        var authPaused = false
        /// 仍在流式输出中的句子 id（= 去空白后的原文）集合。
        /// 超时/结束后移除：迟到的增量不得再上屏（并发在途的多句共用同一
        /// 增量出口，靠这个集合按句隔离）。
        var streamingSentenceIDs: Set<String> = []
    }
    private let stateLock = OSAllocatedUnfairLock(initialState: LiveTranslationState())

    private func mutateState(_ body: (inout LiveTranslationState) -> Void) {
        stateLock.withLock { body(&$0) }
    }

    /// 在途句数，超上限丢弃最新（显示原文兜底）。
    /// 有界并发：每句独立请求（本地/在线服务自带队列与重试），不做串行链——
    /// 串行会让后到的译文错过字幕状态机窗口被丢弃，且体感翻译明显变慢。
    var sentenceTranslationPending: Int { stateLock.withLock { $0.pending } }
    private static let maxPendingSentenceTranslations = 8
    /// 队列上限（AppState 流式入口检查用）。
    static let maxPendingSentenceTranslationsPublic = 8

    /// 连续失败计数（≥3 自动降级为“仅识别模式”）。
    var translationFailureCount: Int { stateLock.withLock { $0.failureCount } }
    /// 认证/不可用错误驱动的自动暂停（区别于用户手动暂停）。
    var translationAuthPaused: Bool { stateLock.withLock { $0.authPaused } }
    /// 降级状态由本管理器回写 AppState.translationUnavailable（UI 绑定）。

    /// 批量翻译任务句柄（取消/退出时统一取消）。
    private var translateTask: Task<Void, Never>?

    // MARK: - 实时句尾翻译

    /// 整句翻译（字幕层检测到一句结束后调用，一次一句、单飞）：
    /// 所有语言统一进入 TranslationProvider；失败返回 nil（显示原文），
    /// 连续失败 3 次自动降级为“仅识别模式”。
    /// 流式整句翻译：逐 token 回调（字幕译文逐字上屏）+ 10s 超时兜底。
    @MainActor
    func translateSentenceStreaming(_ text: String,
                                    onDelta: ((String) -> Void)? = nil) async -> String? {
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
        mutateState {
            $0.pending += 1
            $0.streamingSentenceIDs.insert(trimmed)
        }
        // 正常结束 / 超时 / 取消三条路径都必须释放 pending 槽位并摘掉该句的
        // 流式标记：槽位不释放会在达到并发上限 8 后让所有后续句被永久丢弃；
        // 标记不摘掉则迟到的增量会串到下一句的浮层上。
        defer {
            mutateState {
                $0.pending -= 1
                $0.streamingSentenceIDs.remove(trimmed)
            }
        }

        let provider = Self.provider(for: appState.translationMode)
        // 值捕获锁与回调出口：增量闭包运行在 provider 的 @Sendable 闭包里，
        // 不捕获 self（既避开弱引用/强引用捕获不一致的告警，也让并发在途的
        // 每句各自持有自己那份出口）。
        let streamStateLock = stateLock
        let deltaOutlet = sentenceTranslationDeltaHandler
        do {
            // 超时兜底（与 requestSentenceTranslation 同语义）：provider 挂起时
            // 不能让本句永久占用并发槽位。超时 = 服务慢 ≠ 服务不可用，
            // 故不计入三连失败降级（保持既有计数语义）。
            let result = try await Self.withTimeout(seconds: 10) {
                try await provider.translateStreaming(
                    TranslationRequest(text: trimmed, targetLanguage: targetLang)) { delta in
                    Task { @MainActor in
                        // 该句已超时/结束 → 丢弃迟到增量，避免顶掉别的句子。
                        guard streamStateLock.withLock({
                            $0.streamingSentenceIDs.contains(trimmed)
                        }) else { return }
                        onDelta?(delta)
                        deltaOutlet?(trimmed, delta)
                    }
                }
            }
            mutateState { $0.failureCount = 0 }
            appState.setTranslationUnavailable(false)
            return result.texts.first
        } catch is CancellationError {
            return nil
        } catch is TimeoutError {
            ErrorManager.shared.report(.network, TimeoutError(),
                                       context: "sentence translation streaming timeout")
            return nil
        } catch {
            ErrorManager.shared.report(.api, error, context: "translateSentenceStreaming")
            mutateState { $0.failureCount += 1 }
            if translationFailureCount >= 3 {
                appState.setTranslationUnavailable(true)
                mutateState { $0.authPaused = true }
                appState.showToast("本地翻译服务不可用，已切换到仅识别模式")
            }
            return nil
        }
    }

    /// 流式增量回调出口（桥接层注入：字幕译文逐字渲染）。
    ///
    /// 回调必须携带句子 id：并发上限为 8，相邻两句常在同一 RTT 内结束，
    /// 此前单字段出口会被后一句的 delta 顶掉（译文串台），故按句区分。
    var sentenceTranslationDeltaHandler: ((_ sentenceID: String, _ delta: String) -> Void)?

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
                TranslationRequest(text: trimmed,
                                   targetLanguage: targetLang))
            mutateState { $0.failureCount = 0 }
            appState.setTranslationUnavailable(false)
            return result.texts.first
        } catch is CancellationError {
            // 取消（超时兜底 / 暂停 / 停止）不是服务故障：不计入三连失败。
            return nil
        } catch {
            ErrorManager.shared.report(.api, error, context: "translateSentence")
            mutateState { $0.failureCount += 1 }
            if translationFailureCount >= 3 {
                appState.setTranslationUnavailable(true)
                mutateState { $0.authPaused = true }
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
        mutateState { $0.pending += 1 }
        defer { mutateState { $0.pending -= 1 } }
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
        mutateState { $0.pending = 0 }
    }

    // MARK: - 批量翻译（历史记录整段）

    /// 整段批量翻译：分批（20 句）翻译 + 上下文（前 2 句）参考；
    /// 非瞬时错误（认证/无效端点/本地模型未检测）停止整段并 toast 一次，
    /// 瞬时错误跳过该批继续，最后提示不完整结果。
    @MainActor
    func translate(item: TranscriptionItem, targetLanguage: String) {
        // 「不翻译」模式必须短路：provider(for: .off) 返回在线 provider
        // （映射本身有其他调用方依赖，不能改），不短路会直接打 api.openai.com，
        // 未配置 Key 时必然 401。此处不改动 item，UI 依据 translatedSegments
        // 是否为空决定译文区/清除按钮，填入原文会显示成"译文=原文"。
        guard TranslationMode.current != .off else {
            appState?.showToast("翻译已关闭 — 请先在设置中选择翻译方式")
            return
        }
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
                        TranslationRequest(texts: batch,
                                           targetLanguage: targetLanguage,
                                           previousTranslations: contextPairs))
                    for (offset, translation) in translations.texts.enumerated() {
                        // 下标防御：provider 返回比批大小更长的数组时不得越界。
                        let index = batchStart + offset
                        guard index < item.translatedSegments.count else { break }
                        item.translatedSegments[index] = translation
                    }
                } catch is CancellationError {
                    // 取消不是失败：切换条目/停止时旧任务被 cancel，会让每个
                    // 后续批次在 checkCancellation 处立刻抛出。此前落进下面的
                    // 通用 catch 被计为 transient failure → 弹「翻译不完整」，
                    // 而实际是用户自己的操作（译文照常渲染）。
                    break batchLoop
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
                    // 取消也可能以其它形态抛出（URLError.cancelled 等）。
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        break batchLoop
                    }
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
            // 取消导致的中断不落盘也不报"不完整"：译文未生成是用户主动
            // 中断的结果，不是失败。
            guard !Task.isCancelled else { return }
            self.appState?.history.save(item)
        }
    }

    // MARK: - 停止 / 退出

    /// 停止实时会话时重置翻译状态（在途计数、失败计数、认证暂停）。
    func resetForStop() {
        mutateState {
            $0.pending = 0
            $0.failureCount = 0
            $0.authPaused = false
        }
    }

    /// 清零失败计数并解除认证暂停（自动恢复用：ASRManager 健康检查走这里）。
    ///
    /// 必须同时清 `authPaused`：入口 guard 检查 `!translationAuthPaused`，
    /// 只清 failureCount 会让 3 连败后的降级状态无法自动恢复（此前只有
    /// resetForStop 能解除），自动恢复路径形同虚设。
    func clearFailureCount() {
        mutateState {
            $0.failureCount = 0
            $0.authPaused = false
        }
    }

    /// 取消全部在途翻译任务（应用退出 / 会话停止）。
    func cancelAll() {
        translateTask?.cancel()
        translateTask = nil
        mutateState { $0.pending = 0 }
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
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
