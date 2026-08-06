import Foundation

// MARK: - 翻译方式

/// 实时字幕翻译方式（持久化于 UserDefaults "translationMode"）。
enum TranslationMode: String, CaseIterable, Codable {
    case off
    case localModel
    case onlineAPI

    var label: String {
        switch self {
        case .off: return "不翻译"
        case .localModel: return "本地模型"
        case .onlineAPI: return "在线 API"
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

enum TranslationService {
    /// 翻译配置的 UserDefaults 键。
    enum ConfigKeys {
        static let endpoint = "translationEndpoint"
        static let apiKey = "translationAPIKey"
        static let model = "translationModel"
        static let timeout = "translationTimeout"
        static let maxContext = "translationMaxContext"
        static let temperature = "translationTemperature"
    }

    /// 是否已配置在线 API（端点/密钥至少其一，模型可为空并回退默认值）。
    static var isAPIConfigured: Bool {
        let endpoint = (UserDefaults.standard.string(forKey: ConfigKeys.endpoint) ?? "").trimmingCharacters(in: .whitespaces)
        let apiKey = UserDefaults.standard.string(forKey: ConfigKeys.apiKey) ?? ""
        return !endpoint.isEmpty || !apiKey.isEmpty
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

    static func translateSegmentsWithOpenAI(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = [],
        local: Bool = false
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

        let numberedInputFull = segmentTexts.enumerated()
            .map { "\($0.offset + 1). \($0.element.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")

        // Build context section from previous translations（受最大上下文长度约束）。
        var contextSection = ""
        if !previousTranslations.isEmpty {
            let maxPairs = max(0, min(8, maxContextTokens / 500))
            let pairs = previousTranslations.suffix(maxPairs)
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

        let body: [String: Any] = [
            "model": effectiveModel,
            "messages": [
                ["role": "system", "content": "You are a translator for a live transcription. Translate each numbered line to \(languageName). If a line is already in \(languageName), output it unchanged. Output ONLY the translations in the same numbered format (e.g. \"1. ...\"). Keep exactly \(segmentTexts.count) lines.\(contextSection)"],
                ["role": "user", "content": numberedInput]
            ],
            "temperature": temperature
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performRequestWithRetry(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.parseError
        }

        // Parse numbered lines, stripping the "1. " prefix
        let lines = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line -> String in
                if let range = line.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                    return String(line[range.upperBound...])
                }
                return line
            }

        // Pad or trim to match input count
        if lines.count >= segmentTexts.count {
            return Array(lines.prefix(segmentTexts.count))
        } else {
            return lines + Array(repeating: "", count: segmentTexts.count - lines.count)
        }
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
                try? await Task.sleep(for: backoffs[attempt])
                attempt += 1
                continue
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

        let message = parseErrorMessage(data) ?? "HTTP \(httpResponse.statusCode)"
        switch httpResponse.statusCode {
        case 401, 403:
            throw TranslationError.authFailed(message)
        case 429:
            throw TranslationError.rateLimited(message)
        case 500...599:
            throw TranslationError.serverError(httpResponse.statusCode, message)
        default:
            throw TranslationError.apiFailed(message)
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
