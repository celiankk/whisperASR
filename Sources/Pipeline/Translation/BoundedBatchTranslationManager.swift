import Foundation

// MARK: - 有界并发批量翻译管理器（BoundedBatchTranslationManager）
//
// 长文本批量翻译的并发调度层（P1 性能改造：串行 batch 循环 → 有界并发）：
//
//   TranslationManager.translate(item:)
//         ↓
//   BoundedBatchTranslationManager（actor，本文件）
//         ↓  滑动窗口：并发度恒 ≤ maxConcurrency（2~3）
//   LLMTranslateClient（依赖协议：OpenAI 兼容 API / LM Studio / Apple 均可适配）
//
// 设计要点：
// - 滑动窗口/动态补充：先派发 maxConcurrency 个批次填满水位，此后每回收
//   一个结果立即派发下一个批次——并发池水位恒定，严禁一次性开辟全部 Task；
// - 严格保序：每个批次绑定唯一 batchIndex，结果按位归位后展平，
//   输出顺序与输入 [String] 严格一致（与并发完成顺序无关）；
// - 结构化并发的取消语义：外层 Task 取消 → 子任务级联取消（TaskGroup
//   继承取消态）+ 显式 cancelAll 兜底；任意子批次抛错 → fail-fast
//   取消在途批次并向上一层抛出，不吞 CancellationError；
// - 上下文参考降级为「尽力而为」：并发后第 i 批派发时，前文译句可能
//   尚未完成——只收集**已完成批次**的前 contextSentences 句
//  （原文+译文），缺失则少传/不传，绝不阻塞等待（否则退化为串行）。
//
// actor 隔离说明：调度循环的全部可变状态（nextIndex/results）都是
// translateAll 的局部变量，随方法调用栈生存；子任务闭包不触碰 actor
// 隔离态（走 static nonisolated 路径），网络推理不经过 actor 串行化，
// actor 只承担「派发节拍 + 结果归位」的轻量协调。

/// 批量翻译客户端依赖协议：批量文本 → 等长译文数组。
/// 实现方约定：返回数组长度必须等于 `texts.count`（管理器会归一化兜底）；
/// 实现内部应响应 Task 取消（长轮询/重试循环里 `Task.checkCancellation()`）。
protocol LLMTranslateClient: Sendable {
    /// 翻译一批文本。
    /// - Parameters:
    ///   - texts: 批内原文（批大小由管理器切分，默认 20 句）。
    ///   - targetLanguage: 目标语言 locale id（如 "en"、"zh-Hans"）。
    ///   - context: 前文参考（原文+已译文）对，术语/风格一致性用；
    ///     并发调度下为尽力而为（见文件头注释），可能为空。
    func translateBatch(_ texts: [String],
                        targetLanguage: String,
                        context: [(original: String, translated: String)]) async throws -> [String]
}

/// 现有 TranslationProvider → LLMTranslateClient 桥接适配器。
/// 让本管理器零改动接入既有 Provider 体系（LM Studio / OnlineAPI / Apple）。
struct ProviderBackedTranslateClient: LLMTranslateClient {
    private let provider: TranslationProvider

    init(provider: TranslationProvider) {
        self.provider = provider
    }

    func translateBatch(_ texts: [String],
                        targetLanguage: String,
                        context: [(original: String, translated: String)]) async throws -> [String] {
        let request = TranslationRequest(texts: texts,
                                         targetLanguage: targetLanguage,
                                         previousTranslations: context)
        let result = try await provider.translate(request)
        return result.texts
    }
}

// MARK: - 管理器

actor BoundedBatchTranslationManager {

    // MARK: 配置

    struct Configuration: Sendable {
        /// 单批句数（与既有 translate(item:) 的 batchSize=20 一致）。
        var batchSize: Int = 20
        /// 上下文参考句数（与既有「前 2 句」一致）。
        var contextSentences: Int = 2
        /// 并发度外部注入；存取时收敛到 2~3（业务约束：过低退化为串行、
        /// 过高触发服务端限流/本地模型显存抖动）。
        var maxConcurrency: Int = 3

        var clampedConcurrency: Int {
            min(3, max(2, maxConcurrency))
        }
    }

    /// 单批完成事件（子任务 → 调度循环的结果载体，Sendable）。
    private struct CompletedBatch: Sendable {
        let index: Int
        /// 该批首句在原文数组中的下标（保序归位 + 调用方增量写 UI 用）。
        let sentenceStart: Int
        let translations: [String]
    }

    private let client: LLMTranslateClient
    private let configuration: Configuration

    init(client: LLMTranslateClient, configuration: Configuration = Configuration()) {
        self.client = client
        self.configuration = configuration
    }

    // MARK: - 对外入口

    /// 有界并发批量翻译。
    ///
    /// - Parameters:
    ///   - texts: 原文数组（任意长度，内部按 batchSize 切批）。
    ///   - targetLanguage: 目标语言 locale id。
    ///   - onBatchCompleted: 每批完成的增量回调（批首句下标 + 该批译文，
    ///     顺序与批内原文严格对应）。调用方可借此把译文实时写入
    ///     `item.translatedSegments[batchStart + offset]`——UI 渐进上屏
    ///     且无需等整段完成；回调在调度循环（actor 执行域）内同步触发。
    /// - Returns: 与 `texts` 等长且严格同序的译文数组。
    /// - Throws:
    ///   - 子批次的原始错误（fail-fast：先 cancelAll 再抛出）；
    ///   - `CancellationError`（外层取消，原样上抛不吞不改型）。
    func translateAll(_ texts: [String],
                      targetLanguage: String,
                      onBatchCompleted: (@Sendable (Int, [String]) -> Void)? = nil) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let config = configuration
        let concurrency = config.clampedConcurrency

        // 批次切分：绑定唯一 batchIndex + 批首句绝对下标。
        let batches = Self.makeBatches(texts, batchSize: config.batchSize)
        // 保序归位槽：按 batchIndex 写入，最后展平。
        var results: [[String]?] = Array(repeating: nil, count: batches.count)
        // 滑动窗口游标：下一个待派发的批次下标。
        var nextIndex = 0

        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: CompletedBatch.self) { group in
            // 初派：只开 concurrency 个 Task 填满水位（严禁一次性全量开辟）。
            while nextIndex < batches.count, nextIndex < concurrency {
                self.dispatch(group: &group,
                              batch: batches[nextIndex],
                              texts: texts,
                              targetLanguage: targetLanguage,
                              results: results,
                              config: config)
                nextIndex += 1
            }

            do {
                // 回收节拍：每收到一个完成结果，立即补派下一个批次，
                // 维持「在途批次 ≡ min(剩余批次, maxConcurrency)」的水位。
                while let completed = try await group.next() {
                    results[completed.index] = completed.translations
                    onBatchCompleted?(completed.sentenceStart, completed.translations)

                    if Task.isCancelled { throw CancellationError() }
                    if nextIndex < batches.count {
                        self.dispatch(group: &group,
                                      batch: batches[nextIndex],
                                      texts: texts,
                                      targetLanguage: targetLanguage,
                                      results: results,
                                      config: config)
                        nextIndex += 1
                    }
                }
            } catch {
                // fail-fast / 取消：级联终止全部在途子批次后再抛出。
                // （withTaskGroup 退出时也会隐式取消，这里显式提前，
                // 让网络层尽早停手而不是等作用域收尾。）
                group.cancelAll()
                throw error
            }

            // 保序展平：所有批次必然已归位（group 全收完才到这里）。
            var ordered: [String] = []
            ordered.reserveCapacity(texts.count)
            for slot in results {
                guard let batchTranslations = slot else {
                    throw TranslationError.apiFailed(
                        "Batch result missing — internal scheduling bug")
                }
                ordered.append(contentsOf: batchTranslations)
            }
            return ordered
        }
    }

    // MARK: - 派发与执行

    /// 派发一个批次。闭包内只捕获 Sendable 值并走 static 路径，
    /// 不触碰 actor 隔离态——推理不排队等 actor。
    ///
    /// 上下文（尽力而为）：派发时刻若前文批已完成，取紧邻本批首句的
    /// 最多 contextSentences 句「原文+译文」；未完成则跳过该句，
    /// 绝不 await 等待（等 = 并发退化回串行）。
    private func dispatch(group: inout ThrowingTaskGroup<CompletedBatch, Error>,
                          batch: (index: Int, sentenceStart: Int, texts: [String]),
                          texts: [String],
                          targetLanguage: String,
                          results: [[String]?],
                          config: Configuration) {
        let context = Self.availableContext(forBatchStart: batch.sentenceStart,
                                            texts: texts,
                                            results: results,
                                            contextSentences: config.contextSentences,
                                            batchSize: config.batchSize)
        let client = self.client
        group.addTask {
            // 子任务入口先做取消检查：父任务已取消时新派发立刻短路
            //（网络调用内部也应响应取消，见协议约定）。
            try Task.checkCancellation()
            let translations = try await client.translateBatch(
                batch.texts, targetLanguage: targetLanguage, context: context)
            return CompletedBatch(index: batch.index,
                                  sentenceStart: batch.sentenceStart,
                                  translations: Self.normalized(translations, expectedCount: batch.texts.count))
        }
    }

    // MARK: - 纯函数助手（nonisolated static）

    /// 批次切分：`texts` → [(batchIndex, 批首句绝对下标, 批内文本)]。
    static func makeBatches(_ texts: [String], batchSize: Int) -> [(index: Int, sentenceStart: Int, texts: [String])] {
        let size = max(1, batchSize)
        var batches: [(index: Int, sentenceStart: Int, texts: [String])] = []
        var index = 0
        var start = 0
        while start < texts.count {
            let end = min(start + size, texts.count)
            batches.append((index: index, sentenceStart: start, texts: Array(texts[start..<end])))
            start = end
            index += 1
        }
        return batches
    }

    /// 尽力而为的上下文收集：只取**已完成批次**里紧邻批首句之前的
    /// 最多 `contextSentences` 句（原文+译文），空译文跳过。
    static func availableContext(forBatchStart batchStart: Int,
                                 texts: [String],
                                 results: [[String]?],
                                 contextSentences: Int,
                                 batchSize: Int = 20) -> [(original: String, translated: String)] {
        guard contextSentences > 0, batchStart > 0 else { return [] }
        var pairs: [(original: String, translated: String)] = []
        var sentence = batchStart - 1
        while sentence >= 0, pairs.count < contextSentences {
            let batchIndex = sentence / batchSize
            guard batchIndex < results.count, let translations = results[batchIndex] else {
                // 该句所在批未完成：并发下常见，直接放弃更早的句子
                //（更早的批更可能也没完成），不阻塞等待。
                break
            }
            let offset = sentence - batchIndex * batchSize
            if offset < translations.count, !translations[offset].isEmpty {
                pairs.append((original: texts[sentence], translated: translations[offset]))
            }
            sentence -= 1
        }
        return pairs.reversed()   // 恢复时间正序（旧串行实现语义）
    }

    /// 客户端输出归一化：长度不符时以空串补齐/截断（协议约定的兜底，
    /// 防止上游实现瑕疵打乱保序归位）。
    static func normalized(_ translations: [String], expectedCount: Int) -> [String] {
        if translations.count == expectedCount { return translations }
        var aligned = translations
        if aligned.count > expectedCount {
            aligned.removeLast(aligned.count - expectedCount)
        } else {
            aligned.append(contentsOf: repeatElement("", count: expectedCount - aligned.count))
        }
        return aligned
    }
}
