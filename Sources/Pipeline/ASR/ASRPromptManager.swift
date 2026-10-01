import Foundation

// MARK: - ASR Prompt 管理器（ASRPromptManager）
//
// 语音识别提示词生成 / 管理 / 注入：
//
//   场景输入（手动 / 场景模板 / 历史词库 / AI）
//        ↓
//   Prompt Generator（本类）
//        ↓
//   ASRPrompt（currentPrompt）
//        ↓
//   ASR Provider（WhisperProvider / OnlineASRProvider 请求时注入）
//
// 注入能力：
// - Online ASR：multipart 表单 `prompt` 字段（OpenAI Whisper API 支持）；
// - 本地 Whisper：whisper_full_params.initial_prompt；
// - Nemotron / Qwen：不支持 Prompt，不注入（不受影响）。
//
// 生成时机（避免每句话调用）：
// - 启动识别（ASRManager.startLive）；
// - 切换场景 / 修改配置（ASRPromptConfiguration 属性变更 → 异步 refresh）。
//
// 不修改 ASR Provider 接口：Provider 请求时读取 currentPrompt 自行注入。

final class ASRPromptManager: @unchecked Sendable {
    static let shared = ASRPromptManager()

    /// 注入历史词库数据源（AppRuntimeManager.attach 时注入）。
    weak var appState: AppState?

    /// 保护 `_currentPrompt`。写入点是任意线程（refresh 由配置变更 / 启动
    /// 识别触发），读取点在 WhisperProvider actor 内（推理线程）——
    /// 此前无锁读取是真实数据竞争（读到半更新状态或撕裂的 String）。
    private let lock = NSLock()
    private var _currentPrompt: String?

    /// 当前生效的 Prompt（Provider 注入用；关闭 / 无内容时为 nil）。
    var currentPrompt: String? { lock.withLock { _currentPrompt } }

    /// 写入 Prompt（唯一写入口，持锁；`private(set)` 的加锁等价物）。
    private func setCurrentPrompt(_ value: String?) {
        lock.withLock { _currentPrompt = value }
    }

    /// 始终注入的**书写脚本提示**（与用户的提示词开关无关）。
    ///
    /// 为什么必须有：whisper 在 `language=zh` 下**不区分简繁**，只按音频内容
    /// 猜，实测普通话默认被输出成繁体（"今天天氣很好"）。端到端工作台量到的
    /// 差距是 23.8% → 3.9% 平均字错率，而耗时无变化（1.81s → 1.84s）。
    /// 提示内容是简体汉字，initial_prompt 里出现简体字形会把解码明显拉向简体。
    ///
    /// 放在开关之外的理由：这是**语言正确性**问题，不是"可选优化"——
    /// 把它绑在默认关闭的提示词开关上，等于所有新用户开箱都拿到繁体输出。
    /// 且它只有 8 个字，实测对英文识别无影响（同一英文样本错误率 0.0%）。
    private static let scriptHint = "请用简体中文转写。"

    /// 把脚本提示与用户内容合并（用户内容为空时也保留脚本提示）。
    ///
    /// `internal`（非 private）以便单测直接验证合并语义——这段逻辑决定了
    /// 每次识别真正送进 initial_prompt 的内容，出错会静默影响所有中文识别。
    static func mergedPrompt(base: String?) -> String {
        let trimmed = base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return scriptHint }
        // 用户内容已含脚本提示时不重复追加（用户在自定义提示里自己写过）。
        if trimmed.contains(scriptHint) { return trimmed }
        // 避免重复句号："...。" + "请用..." → 不插入第二个句号。
        let separator = trimmed.hasSuffix("。") || trimmed.hasSuffix(".")
            || trimmed.hasSuffix("；") || trimmed.hasSuffix("\n") ? "" : "。"
        return trimmed + separator + scriptHint
    }

    private func withScriptHint(_ base: String?) -> String {
        Self.mergedPrompt(base: base)
    }

    private init() {}

    /// 重新生成当前 Prompt（启动识别 / 切换场景 / 修改配置时调用）。
    /// 同步来源（手动/场景/历史）立即重算；AI 来源读缓存，缓存为空时异步生成。
    func refresh() {
        let config = ConfigurationManager.shared.asrPrompt
        // 提示词开关关闭时**不再置空**：仍要注入脚本提示，否则中文会输出繁体
        //（见 scriptHint 注释）。用户关掉的是"热词"，不是"语言正确性"。
        guard config.enabled else {
            setCurrentPrompt(withScriptHint(nil))
            return
        }
        switch config.source {
        case .manual:
            setCurrentPrompt(withScriptHint(assemble(base: config.customPrompt)))
        case .scene:
            setCurrentPrompt(withScriptHint(assemble(base: config.sceneTemplate.promptText)))
        case .history:
            setCurrentPrompt(withScriptHint(assemble(base: extractFromHistory())))
        case .ai:
            if !config.aiGeneratedPrompt.isEmpty {
                setCurrentPrompt(withScriptHint(assemble(base: config.aiGeneratedPrompt)))
            } else {
                // 尚未生成：只带脚本提示（不注入未生成的 AI 内容），异步生成后下次 refresh 生效。
                setCurrentPrompt(withScriptHint(nil))
                Task { [weak self] in
                    guard let generated = await self?.generateWithAI() else { return }
                    let cfg = ConfigurationManager.shared.asrPrompt
                    cfg.aiGeneratedPrompt = generated
                    self?.refresh()
                }
            }
        }
    }

    /// 强制重新生成（场景切换 / 手动重新生成按钮）：AI 来源清缓存后重算。
    func regenerate() {
        let config = ConfigurationManager.shared.asrPrompt
        if config.source == .ai {
            config.aiGeneratedPrompt = ""
        }
        refresh()
    }

    // MARK: - Prompt 组装

    /// 基础 Prompt + 附加关键词（逗号分隔 → 顿号连接）。
    private func assemble(base: String) -> String? {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = parsedKeywords()
        if trimmedBase.isEmpty && keywords.isEmpty { return nil }
        var parts: [String] = []
        if !trimmedBase.isEmpty { parts.append(trimmedBase) }
        if !keywords.isEmpty { parts.append("附加词汇：\(keywords.joined(separator: "、"))") }
        return parts.joined(separator: "。")
    }

    /// 解析逗号/顿号分隔的关键词。
    private func parsedKeywords() -> [String] {
        ConfigurationManager.shared.asrPrompt.keywords
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 识别热词（供本地识别引擎注入）。
    /// 来源：附加关键词 + 场景/手动/AI 生成文本中提取的独立词汇。
    var contextualKeywords: [String] {
        let config = ConfigurationManager.shared.asrPrompt
        guard config.enabled else { return [] }
        var keywords = parsedKeywords()
        // 从当前生效 Prompt 文本中提取候选热词（中文片段 / 英文词）。
        if let prompt = currentPrompt {
            let extra = Self.extractKeywords(from: prompt, limit: 20)
            for word in extra where !keywords.contains(word) {
                keywords.append(word)
            }
        }
        return Array(keywords.prefix(60))
    }

    /// 从文本提取热词候选（连续中文片段 ≥2 字 / 英文词 ≥3 字母，过滤停用词）。
    private static func extractKeywords(from text: String, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        if let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9_-]{2,}") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                let word = String(text[r]).lowercased()
                if stopWords.contains(word) { continue }
                counts[word, default: 0] += 1
            }
        }
        if let regex = try? NSRegularExpression(pattern: "[\\u4E00-\\u9FFF]{2,}") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                let word = String(text[r])
                if word.count < 2 { continue }
                counts[word, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    // MARK: - 历史词库

    /// 从历史字幕（最近 50 条）提取高频词 / 专有名词（英文词 + 连续中文片段，
    /// 词频 Top 20，过滤停用词）。
    private func extractFromHistory() -> String {
        guard let appState else { return "" }
        let texts = appState.history.items.prefix(50).map { $0.fullText }
        let joined = texts.joined(separator: " ")

        var counts: [String: Int] = [:]
        // 英文 / 数字词（≥3 字符，含连字符与下划线）。
        if let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9_-]{2,}") {
            let range = NSRange(joined.startIndex..<joined.endIndex, in: joined)
            for match in regex.matches(in: joined, range: range) {
                guard let r = Range(match.range, in: joined) else { continue }
                let word = String(joined[r]).lowercased()
                if Self.stopWords.contains(word) { continue }
                counts[word, default: 0] += 1
            }
        }
        // 连续中文片段（≥2 字）。
        if let regex = try? NSRegularExpression(pattern: "[\\u4E00-\\u9FFF]{2,}") {
            let range = NSRange(joined.startIndex..<joined.endIndex, in: joined)
            for match in regex.matches(in: joined, range: range) {
                guard let r = Range(match.range, in: joined) else { continue }
                let word = String(joined[r])
                if word.count < 2 { continue }
                counts[word, default: 0] += 1
            }
        }

        let top = counts
            .sorted { $0.value > $1.value }
            .prefix(20)
            .map(\.key)
        guard !top.isEmpty else { return "" }
        return "以下词汇可能出现在语音中：\(top.joined(separator: "、"))"
    }

    /// 常见停用词（不进入词库）。
    private static let stopWords: Set<String> = [
        "the", "and", "that", "this", "with", "have", "from", "was", "were", "are",
        "you", "your", "for", "not", "but", "all", "can", "has", "had", "will",
        "our", "their", "they", "them", "what", "when", "where", "who", "how",
        "which", "there", "here", "then", "than", "into", "about", "would",
        "could", "should", "just", "very", "also", "well", "say", "said",
        "了", "的", "是", "我们", "你们", "他们", "这个", "那个", "一个", "什么",
        "怎么", "可以", "没有", "不是", "就是", "还是", "但是", "因为", "所以", "如果",
        "已经", "现在", "时候", "觉得", "知道", "应该", "需要", "大家", "一下",
    ]

    // MARK: - AI 生成

    /// 调用 LLM（复用翻译服务配置的 OpenAI 兼容端点）生成术语表。
    /// 只在启动识别 / 切换场景 / 修改配置时调用（生成结果缓存）。
    private func generateWithAI() async -> String? {
        let translationConfig = ConfigurationManager.shared.translation
        let local = translationConfig.mode == .localModel
        let configuredEndpoint = translationConfig.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = local
            ? (configuredEndpoint.isEmpty
               ? await TranslationService.resolveLocalEndpoint()
               : configuredEndpoint)
            : configuredEndpoint
        guard !endpoint.isEmpty else { return nil }

        let model = translationConfig.model.isEmpty ? "gpt-4o-mini" : translationConfig.model
        let apiKey = translationConfig.apiKey
        let scene = ConfigurationManager.shared.asrPrompt.sceneTemplate.label
        let keywords = parsedKeywords().joined(separator: "、")

        var baseURL = TranslationService.normalizedBaseURL(endpoint)
        if !baseURL.hasSuffix("/chat/completions") {
            if !baseURL.hasSuffix("/") { baseURL += "/" }
            baseURL += "chat/completions"
        }
        guard let url = URL(string: baseURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let userContent = "场景：\(scene)。"
            + (keywords.isEmpty ? "" : "关键词：\(keywords)。")
            + "请为语音识别生成一份简洁的中文热词/术语表（30 个以内），"
            + "覆盖该场景常见专有名词、产品名、人名与专业词汇，"
            + "用逗号分隔，不要编号，不要解释。"
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "你是语音识别提示词专家，输出简洁术语表。"],
                ["role": "user", "content": userContent],
            ],
            "temperature": 0.3,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        AppLogger.shared.log(.asr, "ASR prompt AI generation start")
        do {
            let data = try await TranslationService.performRequestWithRetry(request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLogger.shared.log(.asr, "ASR prompt AI generation done (\(trimmed.count) chars)")
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            AppLogger.shared.log(.asr, "ASR prompt AI generation failed: \(error.localizedDescription)")
            return nil
        }
    }
}
