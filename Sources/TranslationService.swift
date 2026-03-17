import Foundation

struct TargetLanguage: Identifiable, Hashable {
    let id: String   // locale identifier (e.g. "en", "zh-Hans")
    let name: String

    static let available: [TargetLanguage] = [
        .init(id: "en", name: "English"),
        .init(id: "zh-Hans", name: "Chinese (Simplified)"),
        .init(id: "zh-Hant", name: "Chinese (Traditional)"),
        .init(id: "ja", name: "Japanese"),
        .init(id: "ko", name: "Korean"),
        .init(id: "es", name: "Spanish"),
        .init(id: "fr", name: "French"),
        .init(id: "de", name: "German"),
        .init(id: "pt", name: "Portuguese"),
        .init(id: "ru", name: "Russian"),
        .init(id: "ar", name: "Arabic"),
        .init(id: "hi", name: "Hindi"),
        .init(id: "th", name: "Thai"),
        .init(id: "vi", name: "Vietnamese"),
        .init(id: "it", name: "Italian"),
        .init(id: "nl", name: "Dutch"),
        .init(id: "pl", name: "Polish"),
        .init(id: "uk", name: "Ukrainian"),
        .init(id: "tr", name: "Turkish"),
        .init(id: "id", name: "Indonesian"),
    ]
}

enum TranslationError: LocalizedError {
    case invalidEndpoint
    case apiFailed(String)
    case parseError
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid API endpoint URL"
        case .apiFailed(let msg): return "Translation API error: \(msg)"
        case .parseError: return "Failed to parse translation response"
        case .unavailable: return "Translation requires OpenAI API configuration"
        }
    }
}

enum TranslationService {
    static func translateSegmentsWithOpenAI(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = []
    ) async throws -> [String] {
        guard !segmentTexts.isEmpty else { return [] }

        let endpoint = (UserDefaults.standard.string(forKey: "translationEndpoint") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = UserDefaults.standard.string(forKey: "translationAPIKey") ?? ""
        let model = (UserDefaults.standard.string(forKey: "translationModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var baseURL = endpoint.isEmpty ? "https://api.openai.com/v1" : endpoint
        if !baseURL.hasSuffix("/chat/completions") {
            if !baseURL.hasSuffix("/") { baseURL += "/" }
            baseURL += "chat/completions"
        }
        let effectiveModel = model.isEmpty ? "gpt-4o-mini" : model

        guard let url = URL(string: baseURL) else {
            throw TranslationError.invalidEndpoint
        }

        let languageName = TargetLanguage.available.first { $0.id == targetLanguage }?.name ?? targetLanguage

        let numberedInput = segmentTexts.enumerated()
            .map { "\($0.offset + 1). \($0.element.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")

        // Build context section from previous translations
        var contextSection = ""
        if !previousTranslations.isEmpty {
            let pairs = previousTranslations.suffix(2)
                .map { "\"\($0.original)\" → \"\($0.translated)\"" }
                .joined(separator: "\n")
            contextSection = "\n\nPreviously translated segments from this conversation (use as reference for consistent terminology and style):\n\(pairs)"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": effectiveModel,
            "messages": [
                ["role": "system", "content": "You are a translator for a live transcription. Translate each numbered line to \(languageName). If a line is already in \(languageName), output it unchanged. Output ONLY the translations in the same numbered format (e.g. \"1. ...\"). Keep exactly \(segmentTexts.count) lines.\(contextSection)"],
                ["role": "user", "content": numberedInput]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TranslationError.apiFailed("HTTP \(code)")
        }

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
}
