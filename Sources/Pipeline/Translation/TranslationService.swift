import Foundation

// MARK: - 翻译方式

/// 实时字幕翻译方式（持久化于 UserDefaults "translationMode"）。
enum TranslationMode: String, CaseIterable, Codable {
    case off
    case localModel
    case onlineAPI
    case apple

    var label: String {
        switch self {
        case .off: return "不翻译"
        case .localModel: return "本地模型"
        case .onlineAPI: return "在线 API"
        case .apple: return "Apple"
        }
    }

    /// 当前保存的翻译方式。
    static var current: TranslationMode {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "translationMode") == nil {
            // 迁移旧设置：曾开启实时翻译的用户默认走在线 API，避免升级后翻译静默失效。
            return defaults.bool(forKey: "liveTranslationPref") ? .onlineAPI : .off
        }
        return TranslationMode(rawValue: defaults.string(forKey: "translationMode") ?? "") ?? .off
    }
}

struct TargetLanguage: Identifiable, Hashable {
    let id: String        // locale identifier (e.g. "en", "zh-Hans")
    let name: String      // English name (used in API prompts)
    let nativeName: String // native name (displayed in UI)

    static let available: [TargetLanguage] = [
        .init(id: "en", name: "English", nativeName: "English"),
        .init(id: "zh-Hans", name: "Chinese (Simplified)", nativeName: "简体中文"),
        .init(id: "zh-Hant", name: "Chinese (Traditional)", nativeName: "繁體中文"),
        .init(id: "ja", name: "Japanese", nativeName: "日本語"),
        .init(id: "ko", name: "Korean", nativeName: "한국어"),
        .init(id: "es", name: "Spanish", nativeName: "Español"),
        .init(id: "fr", name: "French", nativeName: "Français"),
        .init(id: "de", name: "German", nativeName: "Deutsch"),
        .init(id: "pt", name: "Portuguese", nativeName: "Português"),
        .init(id: "ru", name: "Russian", nativeName: "Русский"),
        .init(id: "ar", name: "Arabic", nativeName: "العربية"),
        .init(id: "hi", name: "Hindi", nativeName: "हिन्दी"),
        .init(id: "th", name: "Thai", nativeName: "ภาษาไทย"),
        .init(id: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
        .init(id: "it", name: "Italian", nativeName: "Italiano"),
        .init(id: "nl", name: "Dutch", nativeName: "Nederlands"),
        .init(id: "pl", name: "Polish", nativeName: "Polski"),
        .init(id: "uk", name: "Ukrainian", nativeName: "Українська"),
        .init(id: "tr", name: "Turkish", nativeName: "Türkçe"),
        .init(id: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
    ]
}

enum TranslationError: LocalizedError {
    case invalidEndpoint
    case apiFailed(String)
    case authFailed(String)
    case rateLimited(String)
    case serverError(Int, String)
    case transport(String)
    case parseError
    case localModelNotDetected
    case unavailable

    // Worded generically ("API error", not "Translation API error") because the
    // meeting-minutes feature shares this client and surfaces the same errors.
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid API endpoint URL"
        case .apiFailed(let msg): return "API error: \(msg)"
        case .authFailed(let msg): return "API key invalid or unauthorized: \(msg)"
        case .rateLimited(let msg): return "Rate-limited by the API: \(msg)"
        case .serverError(let code, let msg): return "API service error (HTTP \(code)): \(msg)"
        case .transport(let msg): return "Network error: \(msg)"
        case .parseError: return "Failed to parse the API response"
        case .localModelNotDetected: return "无法从本地服务获取模型列表 — 请确认本地服务已加载模型，或在设置中填写模型名称"
        case .unavailable: return "Requires an OpenAI-compatible API — set the API key in Settings"
        }
    }

    /// Whether the error is worth retrying (transient). Auth/client errors are not.
    var isRetriable: Bool {
        switch self {
        case .serverError, .transport: return true
        case .invalidEndpoint, .apiFailed, .authFailed, .rateLimited, .parseError, .localModelNotDetected, .unavailable: return false
        }
    }
}

// MARK: - 源语言检测（翻译前分流）

/// 识别出的源语言。中文（简/繁/港）一律直出原文，禁止进入翻译模型。
enum SourceLanguage: String {
    case zhCN
    case zhTW
    case zhHK
    case en
    case ja
    case ko
    case ru
    case other

    var isChinese: Bool {
        switch self {
        case .zhCN, .zhTW, .zhHK: return true
        default: return false
        }
    }

    /// 调试展示用名称。
    var debugName: String {
        switch self {
        case .zhCN: return "zh-CN"
        case .zhTW: return "zh-TW"
        case .zhHK: return "zh-HK"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .ru: return "ru"
        case .other: return "other"
        }
    }
}

// MARK: - 底层翻译实现
//
// 1.4 的统一引擎接口（TranslationEngine / OpenAICompatibleTranslationEngine /
// TranslationEngineFactory）已由 Provider 抽象层取代：
//
//   TranslationManager → TranslationProvider
//     ├── LMStudioProvider  （local: true）
//     └── OnlineAPIProvider （local: false）
//
// 本文件保留 OpenAI 兼容 HTTP 客户端与配置解析，供 Provider 与
// MeetingMinutesService（共享重试客户端）调用，内部实现未改动。

enum TranslationService {
    /// 翻译配置的 UserDefaults 键。
    enum ConfigKeys {
        static let endpoint = "translationEndpoint"
        static let apiKey = "translationAPIKey"
        static let model = "translationModel"
        static let timeout = "translationTimeout"
        static let maxContext = "translationMaxContext"
        static let temperature = "translationTemperature"
        /// 自定义翻译系统提示词（空 = 使用默认翻译指令）。
        static let systemPrompt = "translationSystemPrompt"
    }

    /// 是否已配置在线 API（端点/密钥至少其一，模型可为空并回退默认值）。
    static var isAPIConfigured: Bool {
        let endpoint = (UserDefaults.standard.string(forKey: ConfigKeys.endpoint) ?? "").trimmingCharacters(in: .whitespaces)
        let apiKey = UserDefaults.standard.string(forKey: ConfigKeys.apiKey) ?? ""
        return !endpoint.isEmpty || !apiKey.isEmpty
    }

    /// 简体标记字（出现即倾向于 zh-CN）。
    private static let simplifiedMarkers = Set<Character>("们吗里为这个说时候后来对没从还让学问题发现进过开关点觉务处于国区体现识议车间长来")
    /// 繁体标记字（出现即倾向于 zh-TW/zh-HK）。
    private static let traditionalMarkers = Set<Character>("們嗎裡為這個說時後來對沒從還讓學問題發現進過開關點覺務處於國區體見識議車間長來")
    /// 粤语（zh-HK）标记字。
    private static let hkMarkers = Set<Character>("嘅咗嚟喺唔係乜嘢啲")

    /// 检测一批字幕文本的源语言（按字符区间统计，不依赖翻译模型）。
    static func detectSourceLanguage(_ texts: [String]) -> SourceLanguage {
        let joined = texts.joined(separator: " ")
        var han = 0, kana = 0, hangul = 0, cyrillic = 0, latin = 0
        for scalar in joined.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                han += 1
            } else if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) {
                kana += 1
            } else if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) {
                hangul += 1
            } else if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
                cyrillic += 1
            } else if (0x0041...0x007A).contains(v) {
                latin += 1
            }
        }
        if kana > 0 { return .ja }
        if hangul > 0 { return .ko }
        if cyrillic > 0 { return .ru }
        if han > 0 { return chineseVariant(joined) }
        if latin > 0 { return .en }
        return .other
    }

    /// 中文变体：粤语标记优先（zh-HK），繁体次之（zh-TW），否则简体（zh-CN）。
    private static func chineseVariant(_ text: String) -> SourceLanguage {
        let chars = Set(text)
        let hkCount = chars.intersection(hkMarkers).count
        if hkCount > 0 { return .zhHK }
        let traditionalCount = chars.intersection(traditionalMarkers).count
        let simplifiedCount = chars.intersection(simplifiedMarkers).count
        return traditionalCount > simplifiedCount ? .zhTW : .zhCN
    }

    /// 本地模型服务候选（LM Studio / Ollama / llama.cpp 服务器 / 本应用 API 服务器）。
    private static let localEndpointCandidates = [
        "http://127.0.0.1:1234/v1",
        "http://127.0.0.1:11434/v1",
        "http://127.0.0.1:8080/v1",
    ]

    /// 把用户填写的端点归一化为 OpenAI 兼容 base URL（确保带 `/v1` 前缀）。
    /// 兼容以下写法，避免把请求发到缺失 `/v1` 的路径上（如 LM Studio 只服务
    /// `/v1/chat/completions`，`/chat/completions` 会 404/返回非 OpenAI 格式）：
    /// - "http://127.0.0.1:1234"                     -> "http://127.0.0.1:1234/v1"
    /// - "http://127.0.0.1:1234/v1/"                 -> "http://127.0.0.1:1234/v1"
    /// - "http://127.0.0.1:1234/v1/chat/completions" -> 原样返回
    static func normalizedBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme != nil, components.host != nil else {
            return trimmed
        }
        let path = components.path
        // 已是完整 chat 端点时不再拼接。
        if path.hasSuffix("/chat/completions") {
            return trimmed
        }
        // 路径中还没有 v1 段时补上 OpenAI 兼容前缀。
        if !path.split(separator: "/").contains("v1") {
            components.path = "/v1" + path
        }
        return components.url?.absoluteString ?? trimmed
    }

    /// 本地模式：依次探测可用的 OpenAI 兼容服务，返回第一个可用的 base URL。
    /// 用户配置了 translationEndpoint 时优先使用。
    static func resolveLocalEndpoint() async -> String {
        let configured = (UserDefaults.standard.string(forKey: ConfigKeys.endpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return normalizedBaseURL(configured)
        }
        for candidate in localEndpointCandidates {
            if await isLocalServerReachable(candidate) {
                return candidate
            }
        }
        return localEndpointCandidates[0]
    }

    /// 本地模式：从 /v1/models 取第一个模型 id；失败返回 nil（由调用方回退）。
    static func fetchFirstLocalModel(baseURL: String) async -> String? {
        let base = normalizedBaseURL(baseURL)
        guard let url = URL(string: base.hasSuffix("/") ? base + "models" : base + "/models") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]],
              let first = models.first,
              let id = first["id"] as? String, !id.isEmpty else {
            return nil
        }
        return id
    }

    private static func isLocalServerReachable(_ base: String) async -> Bool {
        let normalized = normalizedBaseURL(base)
        guard let url = URL(string: normalized.hasSuffix("/") ? normalized + "models" : normalized + "/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - 思考模型兼容（每模型禁思考 / reasoning 分离）

    /// 思考控制：自动识别 或 手动指定厂商组（自部署/改名模型 auto 识别
    /// 不了时的兜底）或不发送。各厂商组禁思考参数不同：
    /// - DeepSeek·火山方舟·GLM：thinking.type=disabled
    /// - Qwen·百炼·硅基流动：顶层 enable_thinking=false
    /// - vLLM·SGLang 自部署：chat_template_kwargs.enable_thinking=false
    /// - OpenAI·Grok：reasoning_effort="none"
    enum ThinkingControl: String, CaseIterable {
        case auto
        case deepseekGlm = "deepseek_glm"
        case qwen = "qwen"
        case vllm = "vllm"
        case openai = "openai"
        case none_ = "none"

        var label: String {
            switch self {
            case .auto: return "自动识别"
            case .deepseekGlm: return "DeepSeek·火山方舟·GLM"
            case .qwen: return "Qwen·百炼·硅基流动"
            case .vllm: return "vLLM·SGLang 自部署"
            case .openai: return "OpenAI·Grok"
            case .none_: return "不发送"
            }
        }

        static var current: ThinkingControl {
            let raw = UserDefaults.standard.string(forKey: "translationThinkingControl") ?? ""
            // 旧值 off（强制禁用-自动挑参）并入 auto；未知值回落 auto。
            return raw == "off" ? .auto : (ThinkingControl(rawValue: raw) ?? .auto)
        }

        /// 该组的禁思考请求参数。
        var requestBody: [String: Any] {
            switch self {
            case .auto, .none_: return [:]
            case .deepseekGlm: return ["thinking": ["type": "disabled"]]
            case .qwen: return ["enable_thinking": false]
            case .vllm: return ["chat_template_kwargs": ["enable_thinking": false]]
            case .openai: return ["reasoning_effort": "none"]
            }
        }
    }

    /// 按当前思考控制设置注入请求参数（auto = 按模型名识别组别，
    /// 识别不出不发送；手动组 = 无条件用该组参数）。
    static func thinkingControlBody(for model: String) -> [String: Any] {
        let control = ThinkingControl.current
        switch control {
        case .auto:
            let lower = model.lowercased()
            guard lower.contains("r1") || lower.contains("deepseek-reasoner")
                || lower.contains("glm-4") || lower.contains("qwen3") || lower.contains("qwq")
                || lower.contains("thinking") || lower.contains("gpt") || lower.contains("grok")
            else { return [:] }
            if lower.contains("gpt") || lower.contains("grok") {
                return ThinkingControl.openai.requestBody
            }
            if lower.contains("qwen3") { return ThinkingControl.qwen.requestBody }
            if lower.contains("glm-4") { return ThinkingControl.deepseekGlm.requestBody }
            return ThinkingControl.vllm.requestBody
        case .deepseekGlm, .qwen, .vllm, .openai:
            return control.requestBody
        case .none_:
            return [:]
        }
    }

    /// 非流式响应的消息内容提取（思考分离）：content 为空且
    /// reasoning_content 非空时取 reasoning 尾部（部分网关把正文误放 reasoning）。
    static func extractContent(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        if let reasoning = message["reasoning_content"] as? String,
           !reasoning.isEmpty,
           let tail = reasoning.split(separator: "\n").last,
           !tail.isEmpty {
            return String(tail)
        }
        return nil
    }

    // MARK: - 流式翻译（单句实时，逐 token 回调）

    /// 单句流式翻译：SSE 逐 token 回调增量（delta.content），
    /// 思考增量（reasoning_content）静默丢弃。完成返回完整译文。
    /// 批量翻译仍走 translateSegmentsWithOpenAI（需要整体对齐解析）。
    static func translateStreaming(
        segmentText: String,
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = [],
        local: Bool = false,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let results = try await translateSegmentsWithOpenAI(
            segmentTexts: [segmentText],
            targetLanguage: targetLanguage,
            previousTranslations: previousTranslations,
            local: local,
            stream: true,
            onDelta: { delta in onDelta(delta) })
        return results.first ?? ""
    }

    static func translateSegmentsWithOpenAI(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = [],
        local: Bool = false
    ) async throws -> [String] {
        try await translateSegmentsWithOpenAI(
            segmentTexts: segmentTexts, targetLanguage: targetLanguage,
            previousTranslations: previousTranslations, local: local,
            stream: false, onDelta: nil)
    }

    static func translateSegmentsWithOpenAI(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = [],
        local: Bool = false,
        stream: Bool = false,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> [String] {
        guard !segmentTexts.isEmpty else { return [] }

        let configuredEndpoint = (UserDefaults.standard.string(forKey: ConfigKeys.endpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 本地模式：配置地址优先，否则自动探测本地服务；在线模式默认 OpenAI。
        let endpoint = local
            ? (configuredEndpoint.isEmpty ? await resolveLocalEndpoint() : configuredEndpoint)
            : configuredEndpoint
        let apiKey = UserDefaults.standard.string(forKey: ConfigKeys.apiKey) ?? ""
        let configuredModel = (UserDefaults.standard.string(forKey: ConfigKeys.model) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timeout = max(5, UserDefaults.standard.double(forKey: ConfigKeys.timeout) == 0
                          ? 30 : UserDefaults.standard.double(forKey: ConfigKeys.timeout))
        let maxContextTokens = max(256, UserDefaults.standard.integer(forKey: ConfigKeys.maxContext) == 0
                                   ? 16000 : UserDefaults.standard.integer(forKey: ConfigKeys.maxContext))
        let temperature = max(0, min(2, UserDefaults.standard.double(forKey: ConfigKeys.temperature) == 0
                                     ? 0.3 : UserDefaults.standard.double(forKey: ConfigKeys.temperature)))

        var baseURL = endpoint.isEmpty
            ? (local ? "http://127.0.0.1:1234/v1" : "https://api.openai.com/v1")
            : normalizedBaseURL(endpoint)
        // 本地模式且未配置模型名：自动取服务第一个模型。
        var effectiveModel = configuredModel
        if local, effectiveModel.isEmpty {
            if let detected = await fetchFirstLocalModel(baseURL: baseURL) {
                effectiveModel = detected
            } else {
                throw TranslationError.localModelNotDetected
            }
        }
        if effectiveModel.isEmpty {
            effectiveModel = "gpt-4o-mini"
        }
        if !baseURL.hasSuffix("/chat/completions") {
            if !baseURL.hasSuffix("/") { baseURL += "/" }
            baseURL += "chat/completions"
        }

        guard let url = URL(string: baseURL) else {
            throw TranslationError.invalidEndpoint
        }

        let languageName = TargetLanguage.available.first { $0.id == targetLanguage }?.name ?? targetLanguage

        // 翻译输入归一化（NFKC）：全角英数字/标点 → 半角标准形
        //（ASR 偶发输出全半角混排，归一化提升 LLM 翻译稳定性；
        // 对 CJK 表意文字无影响）。显示层不动——用户看到的字幕保持原样。
        let normalizedTexts = segmentTexts.map(Self.normalizeForTranslation)
        let numberedInputFull = normalizedTexts.enumerated()
            .map { "\($0.offset + 1). \($0.element.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")

        // Build context section from previous translations（受最大上下文长度约束）。
        var contextSection = ""
        if !previousTranslations.isEmpty {
            // 上下文轮数可配（设置 → 翻译；默认 2，0 = 关闭）。
            let configuredRounds = UserDefaults.standard.integer(forKey: "translationContextRounds")
            let rounds = configuredRounds == 0 && UserDefaults.standard.object(forKey: "translationContextRounds") == nil
                ? 2 : max(0, min(8, configuredRounds))
            let maxPairs = min(rounds, max(1, maxContextTokens / 500))
            let pairs = previousTranslations.suffix(max(0, maxPairs))
                .map { "\"\($0.original)\" → \"\($0.translated)\"" }
                .joined(separator: "\n")
            if !pairs.isEmpty {
                contextSection = "\n\nPreviously translated segments from this conversation (use as reference for consistent terminology and style):\n\(pairs)"
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 本地服务通常不需要密钥；空密钥时不发送 Authorization 头。
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout

        // 按最大上下文长度（tokens ≈ 4 字符/token）截断输入，防止超长请求。
        let maxInputCharacters = maxContextTokens * 4
        let numberedInput = numberedInputFull.count <= maxInputCharacters
            ? numberedInputFull
            : String(numberedInputFull.prefix(maxInputCharacters))

        // 自定义翻译系统提示词（设置 → 翻译 → 系统提示词）为空时用默认指令。
        // 首次安装（无任何 Prompt 配置）：落默认预设「视频字幕」（应用核心
        // 场景是实时字幕）——落盘必须在运行时读取点，只放设置页 onAppear
        // 时用户不进设置页就永远不生效。已有配置（含显式清空）不覆盖。
        // 变量替换统一走 PromptBuilder（唯一收口）：模板含 {text} 时文本
        // 已嵌入模板（system 内），user 消息仍发编号原文（批量格式解析
        // 依赖编号行）；不含变量时保持现行结构（模板作指令，文本走 user）。
        let rawPrompt = UserDefaults.standard.string(forKey: ConfigKeys.systemPrompt) ?? ""
        let hasPresetSelection = UserDefaults.standard.string(forKey: "translationPromptPreset") != nil
        var customPromptTemplate: String
        if rawPrompt.isEmpty && !hasPresetSelection {
            // 首次安装：落默认预设（显式保存过空模板 = hasPresetSelection
            // 非nil，不进入此分支——用户「清空自定义」的意图受尊重）。
            let defaultPreset = TranslationPromptPreset.with(id: TranslationPromptPreset.defaultID)
            customPromptTemplate = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if let defaultPreset {
                UserDefaults.standard.set(defaultPreset.prompt, forKey: ConfigKeys.systemPrompt)
                UserDefaults.standard.set(defaultPreset.id, forKey: "translationPromptPreset")
                customPromptTemplate = defaultPreset.prompt
            }
        } else {
            customPromptTemplate = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 三铁律（无论默认/自定义模板都生效）：
        // 1) 只输出一条最佳译文（禁止备选/注释/解释）；
        // 2) 专名与品牌名保留原文不译；
        // 3) 依据上下文与常识纠正 ASR 识别错误（容错下沉到 LLM 层）。
        let ironRules = " Output ONLY one best translation per line — no alternatives, no parenthetical notes, no explanations. Keep proper nouns and brand names in the original language. Silently fix obvious ASR misrecognitions using context and common sense."
        let baseInstruction: String
        if customPromptTemplate.isEmpty {
            baseInstruction = "You are a translator for a live transcription. Translate each numbered line to \(languageName). If a line is already in \(languageName), output it unchanged." + ironRules
        } else {
            let rendered = PromptBuilder.build(
                template: customPromptTemplate,
                context: TranslationPromptContext(
                    // 源语言：实时场景 ASR 自动检测，模板未显式指定时用
                    // "the source language"（避免编造）；目标语言取配置全名。
                    sourceLanguage: "the detected source language",
                    targetLanguage: languageName,
                    text: numberedInput))
            baseInstruction = rendered + ironRules
        }
        let formatInstruction: String
        if segmentTexts.count > 1 {
            formatInstruction = " Output ONLY a JSON array of exactly \(segmentTexts.count) translated strings in order, e.g. [\"...\", \"...\"]. No other text."
        } else {
            formatInstruction = " Output ONLY the translation itself, no explanations, no numbering."
        }
        let systemContent = baseInstruction + formatInstruction + contextSection

        // 上下文双路径：自定义模板含 {context} 占位符 → 历史嵌入 system
        //（contextSection 已含）；否则历史转 user/assistant 交替多轮消息
        //（对话形态 token 效率更高，LLM 指代消解更强）。
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemContent],
        ]
        if customPromptTemplate.contains("{context}"), !previousTranslations.isEmpty {
            // 占位符路径：contextSection 已在 system 内，无需多轮。
        } else if !previousTranslations.isEmpty {
            let history = previousTranslations.suffix(10)
            for pair in history {
                messages.append(["role": "user", "content": pair.original])
                messages.append(["role": "assistant", "content": pair.translated])
            }
        }
        messages.append(["role": "user", "content": numberedInput])

        var body: [String: Any] = [
            "model": effectiveModel,
            "messages": messages,
            "temperature": temperature,
            "stream": stream
        ]
        // 思考模型禁思考参数（每模型自动/强制关/不发送；见 thinkingControlBody）。
        for (key, value) in thinkingControlBody(for: effectiveModel) {
            body[key] = value
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 流式路径：SSE 逐 token，delta.content 喂 onDelta（思考增量丢弃），
        // 拼接完整译文后按格式解析（单句直接返回）。
        if stream {
            let full = try await performStreamingRequest(request, onDelta: onDelta)
            if segmentTexts.count == 1 {
                return [Self.stripSingleLineNoise(full)]
            }
            if let json = Self.parseTranslationArray(full, count: segmentTexts.count) {
                return json
            }
            // JSON 解析失败回退编号解析。
            return Self.parseNumberedLines(full, count: segmentTexts.count)
        }

        let data = try await performRequestWithRetry(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw TranslationError.parseError
        }
        // #8 空 completion 诊断：有 tokens 消耗但内容空 = reasoning 烧光
        // max_tokens 预算（思考模型常见），明确指路而非笼统 parseError。
        if let content = Self.extractContent(from: message), !content.isEmpty {
            // #7 复读机检测：长输出的周期性重复（小模型循环输出）。
            if Self.hasRepetition(content) {
                AppLogger.shared.log(.translation,
                    "Repetition detected (\(content.count) chars) — possible model loop, treating as failure")
                throw TranslationError.apiFailed("翻译模型输出重复循环，请重试或更换模型")
            }
        } else if let usage = json["usage"] as? [String: Any],
                  let completionTokens = usage["completion_tokens"] as? Int,
                  completionTokens > 0 {
            AppLogger.shared.log(.translation,
                "Empty translation but \(completionTokens) completion tokens — max_tokens likely consumed by reasoning; adjust thinking mode or increase max tokens")
            throw TranslationError.apiFailed("译文为空：思考过程耗尽了输出预算（请调整思考模式或增大 max_tokens）")
        }
        guard let content = Self.extractContent(from: message) else {
            throw TranslationError.parseError
        }

        // 批量优先 JSON 数组解析；失败回退编号行解析（旧模型兼容）。
        if segmentTexts.count > 1, let array = Self.parseTranslationArray(content, count: segmentTexts.count) {
            return array
        }
        return Self.parseNumberedLines(content, count: segmentTexts.count)
    }

    /// 复读机检测：≥40 字输出中，8 字片段重复 ≥3 次 **且重复覆盖文本 ≥30%**
    /// 才判循环输出（循环输出覆盖通常 >80%；正常文本偶现短语重复不达标）。
    static func hasRepetition(_ text: String, minLength: Int = 40,
                              chunkSize: Int = 8, repeats: Int = 3,
                              coverageRatio: Double = 0.3) -> Bool {
        let chars = Array(text)
        guard chars.count >= minLength else { return false }
        var counts: [String: Int] = [:]
        for start in 0...(chars.count - chunkSize) {
            let chunk = String(chars[start..<(start + chunkSize)])
            counts[chunk, default: 0] += 1
        }
        let maxCount = counts.values.max() ?? 0
        guard maxCount >= repeats else { return false }
        // 覆盖率：该片段（非重叠）铺开占文本比例。
        let coverage = Double(maxCount * chunkSize) / Double(chars.count)
        return coverage >= coverageRatio
    }

    /// 翻译输入归一化：NFKC 兼容分解（全角→半角、上标/连字标准化）+ 首尾 trim。
    static func normalizeForTranslation(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 响应解析

    /// 编号行解析（"1. xxx" 前缀剥离；数量对齐补空/截断）。
    static func parseNumberedLines(_ content: String, count: Int) -> [String] {
        let lines = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line -> String in
                if let range = line.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                    return String(line[range.upperBound...])
                }
                return line
            }
        if lines.count >= count {
            return Array(lines.prefix(count))
        }
        return lines + Array(repeating: "", count: count - lines.count)
    }

    /// JSON 数组解析：剥离 markdown 代码围栏后取 [ ... ]，长度不符返回 nil
    ///（由调用方回退编号解析）。防批量串句：数组序即句序。
    static func parseTranslationArray(_ content: String, count: Int) -> [String]? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else {
            return nil
        }
        guard let data = String(text[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        let strings = array.map { (($0 as? String) ?? "\($0)").trimmingCharacters(in: .whitespaces) }
        guard strings.count == count else { return nil }
        return strings
    }

    /// 单句流式结果的净化：剥离可能的编号前缀与代码围栏。
    static func stripSingleLineNoise(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = result.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
            result = String(result[range.upperBound...])
        }
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SSE 流式请求

    /// SSE chat/completions 流式请求：逐行解析 `data: {...}`，
    /// choices[0].delta.content → onDelta（reasoning_content 丢弃）。
    /// 返回拼接的完整 content。
    private static func performStreamingRequest(
        _ request: URLRequest,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationError.apiFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty
            else { continue }
            full += content
            onDelta?(content)
        }
        guard !full.isEmpty else { throw TranslationError.parseError }
        return full
    }

    /// Send the request with up to 2 retries (3 attempts total) for transient failures
    /// (URLSession transport errors and 5xx). Auth/client errors are never retried.
    /// Shared with MeetingMinutesService, which talks to the same API.
    static func performRequestWithRetry(_ request: URLRequest) async throws -> Data {
        let backoffs: [Duration] = [.milliseconds(500), .milliseconds(1500)]
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await performRequest(request)
            } catch let err as TranslationError where err.isRetriable && attempt < backoffs.count {
                AppLogger.shared.log(
                    .translation,
                    "Request failed (attempt \(attempt + 1), retrying): \(err.localizedDescription)"
                )
                try? await Task.sleep(for: backoffs[attempt])
                attempt += 1
                continue
            } catch {
                AppLogger.shared.log(.translation, "Request failed (no retry): \(error.localizedDescription)")
                throw error
            }
        }
    }

    private static func performRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslationError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.transport("Invalid response")
        }
        if (200...299).contains(httpResponse.statusCode) {
            return data
        }

        // 错误增强：URL / 状态码 / 模型 / 服务器返回内容。
        let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
        let message = parseErrorMessage(data) ?? "HTTP \(httpResponse.statusCode)"
        let requestURL = request.url?.absoluteString ?? "unknown"
        let modelName = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            as? [String: Any])?["model"] as? String ?? "unknown"
        let detail = "\(message)（URL: \(requestURL)，模型: \(modelName)，响应: \(bodyPreview)）"
        switch httpResponse.statusCode {
        case 401, 403:
            throw TranslationError.authFailed(detail)
        case 429:
            throw TranslationError.rateLimited(detail)
        case 500...599:
            throw TranslationError.serverError(httpResponse.statusCode, detail)
        default:
            throw TranslationError.apiFailed(detail)
        }
    }

    /// Extract `error.message` from an OpenAI-style error body.
    private static func parseErrorMessage(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        else { return nil }
        return message
    }
}
