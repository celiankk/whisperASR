import Foundation
import Observation

// MARK: - Minutes Prompt

/// A user-configurable instruction template for generating meeting minutes.
struct MinutesPrompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var prompt: String
}

// MARK: - Prompt Store

/// Owns the minutes prompt templates (persisted as JSON in UserDefaults) and
/// the currently selected template. Always contains at least one prompt — the
/// built-in default is re-seeded if the user deletes everything.
@MainActor
@Observable
final class MinutesPromptStore {
    static let shared = MinutesPromptStore()

    // nonisolated: BackupService reads these from nonisolated code.
    nonisolated static let promptsKey = "minutesPrompts"
    nonisolated static let selectedKey = "selectedMinutesPromptID"
    nonisolated static let contextTokensKey = "minutesContextTokens"
    nonisolated static let defaultContextTokens = 16_000

    var prompts: [MinutesPrompt]
    var selectedPromptID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPromptID?.uuidString, forKey: Self.selectedKey)
        }
    }

    private init() {
        prompts = Self.loadPrompts()
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey) {
            selectedPromptID = UUID(uuidString: raw)
        }
    }

    /// The template used when generating without an explicit choice.
    var selectedPrompt: MinutesPrompt {
        prompts.first { $0.id == selectedPromptID } ?? prompts[0]
    }

    func upsert(_ prompt: MinutesPrompt) {
        if let idx = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[idx] = prompt
        } else {
            prompts.append(prompt)
        }
        persist()
    }

    func delete(_ prompt: MinutesPrompt) {
        prompts.removeAll { $0.id == prompt.id }
        if prompts.isEmpty {
            prompts = [Self.defaultPrompt()]
        }
        if selectedPromptID == prompt.id {
            selectedPromptID = prompts[0].id
        }
        persist()
    }

    /// Re-read from UserDefaults after an external write (backup restore).
    func reloadFromDefaults() {
        prompts = Self.loadPrompts()
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey) {
            selectedPromptID = UUID(uuidString: raw)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(prompts) {
            UserDefaults.standard.set(data, forKey: Self.promptsKey)
        }
    }

    private static func loadPrompts() -> [MinutesPrompt] {
        if let data = UserDefaults.standard.data(forKey: promptsKey),
           let decoded = try? JSONDecoder().decode([MinutesPrompt].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return [defaultPrompt()]
    }

    static func defaultPrompt() -> MinutesPrompt {
        MinutesPrompt(
            name: "Default Meeting Minutes",
            prompt: """
            Write structured meeting minutes from the transcript. Include:

            - Meeting title: a short descriptive title inferred from the content
            - Overview: a 2-4 sentence summary of the meeting's purpose and outcome
            - Key discussion points: grouped by topic, with the important arguments and context
            - Decisions made: each decision with its rationale
            - Action items: a table of task, owner (if identifiable), and deadline (if mentioned)
            - Open questions: unresolved issues to follow up on

            Write the minutes in the same language as the transcript. Be faithful to the \
            content; do not invent details that are not in the transcript. Omit any section \
            that has no content.
            """
        )
    }

    /// The configured model context window, floored to something workable.
    static func contextTokens() -> Int {
        let stored = UserDefaults.standard.integer(forKey: contextTokensKey)
        let value = stored == 0 ? defaultContextTokens : stored
        return max(4_000, value)
    }
}

// MARK: - Minutes Generation Service

/// Generates meeting minutes from a transcript via the same OpenAI-compatible
/// chat API configured for translation. Transcripts that exceed the configured
/// context window are map-reduced: per-chunk note extraction, hierarchical
/// condensation if needed, then a final pass that applies the user's prompt.
enum MeetingMinutesService {

    /// Tokens reserved for the response and prompt overhead within the context window.
    private static let outputReserveTokens = 2_048

    private static let minutesSystemPrompt = """
    You are a professional meeting-minutes writer. Follow the user's instructions to \
    produce meeting minutes from a transcript.
    Output rules:
    - Respond with ONLY an HTML fragment (the content that would go inside <body>). \
    No markdown, no code fences, no <html>, <head> or <body> tags.
    - Use semantic HTML: <h1> for the title, <h2> for section headings, <p> for prose, \
    <ul>/<ol> for lists, and <table> with <thead>/<tbody> for tabular data such as action items.
    - Write in the same language as the transcript unless the instructions say otherwise.
    """

    private static func notesSystemPrompt(part: Int, of total: Int) -> String {
        """
        You are processing part \(part) of \(total) of a long meeting transcript. \
        Extract detailed notes in plain text bullet points, preserving: topics discussed, \
        who said what (when identifiable), decisions, action items, numbers, dates, and names. \
        Write the notes in the same language as the transcript. Do not write final minutes yet; \
        output only the notes.
        """
    }

    private static let condenseSystemPrompt = """
    You are condensing meeting notes that are too long to process at once. Merge the notes \
    into a shorter set of plain-text bullet points, keeping every decision, action item, \
    number, date, and name. Write in the same language as the notes. Output only the notes.
    """

    /// Generate minutes and return an HTML fragment.
    static func generateMinutes(
        transcriptLines: [String],
        instructions: String,
        contextTokens: Int,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let inputBudget = max(1_024, contextTokens - outputReserveTokens)
        let transcript = transcriptLines.joined(separator: "\n")

        // 预算必须计入系统提示与用户指令：此前只比较 transcript 自身长度，
        // 指令很长（自定义模板）时会静默超预算，请求被服务端截断或报错。
        let instructionsTokens = estimatedTokens(instructions)
        let minutesSystemTokens = estimatedTokens(minutesSystemPrompt)
        let singlePassFixed = minutesSystemTokens + instructionsTokens
            + estimatedTokens(transcriptLabel) + budgetSlackTokens
        if estimatedTokens(transcript) + singlePassFixed <= inputBudget {
            await onProgress("Writing minutes…")
            return try await chat(
                system: minutesSystemPrompt,
                user: instructions + transcriptLabel + transcript)
        }

        // Map: extract notes from each chunk.
        // 每个请求的可用预算 = 输入预算 − 该系统提示与固定标签开销。
        let mapBudget = max(512, inputBudget - estimatedTokens(notesSystemPrompt(part: 1, of: 1))
            - budgetSlackTokens)
        let condenseBudget = max(512, inputBudget - estimatedTokens(condenseSystemPrompt)
            - budgetSlackTokens)
        let chunks = chunk(lines: transcriptLines, budget: mapBudget)
        var notes: [String] = []
        for (i, part) in chunks.enumerated() {
            try Task.checkCancellation()
            await onProgress("Summarizing part \(i + 1) of \(chunks.count)…")
            notes.append(try await chat(
                system: notesSystemPrompt(part: i + 1, of: chunks.count),
                user: clipToBudget(part, budget: mapBudget)))
        }

        // Reduce hierarchically until the merged notes fit the budget.
        var rounds = 0
        while notes.count > 1, estimatedTokens(notes.joined(separator: "\n\n")) > inputBudget, rounds < 3 {
            try Task.checkCancellation()
            await onProgress("Condensing notes…")
            let groups = chunk(lines: notes, budget: condenseBudget)
            var condensed: [String] = []
            for group in groups {
                try Task.checkCancellation()
                // 单条 note 自身超预算时 chunk 只能整条成组（安全阀），
                // 这里再按预算裁剪，避免 condense 请求本身超限。
                condensed.append(try await chat(
                    system: condenseSystemPrompt,
                    user: clipToBudget(group, budget: condenseBudget)))
            }
            notes = condensed
            rounds += 1
        }

        // 预算校验（提交前的最后一道闸）：
        // `rounds < 3` 是防死循环的硬闸，**不是**预算保证——超长会议可能在
        // 闸后仍然超限。此前无条件提交全部 notes，必然超出上下文窗口
        // （请求被截断/报错，用户只看到一次失败）。这里在预算内装配 notes：
        // 超限则按每段配额截断（保留每段首尾——结论/行动项常出现在段尾），
        // 连最小配额都装不下时抛可读错误。
        let finalFixed = minutesSystemTokens + instructionsTokens
            + estimatedTokens(finalPromptPreamble) + budgetSlackTokens
        let notesBudget = inputBudget - finalFixed
        guard let fitted = fitNotesToBudget(notes, budget: notesBudget) else {
            throw MinutesError.transcriptTooLong(
                estimatedNotesTokens: estimatedTokens(notes.joined(separator: "\n\n")) + finalFixed,
                inputBudget: inputBudget)
        }
        if fitted.truncated {
            AppLogger.shared.log(
                .translation,
                "MeetingMinutes: notes truncated to fit the \(inputBudget)-token input budget "
                + "(notes budget \(notesBudget))")
        }

        try Task.checkCancellation()
        await onProgress("Writing minutes…")
        return try await chat(
            system: minutesSystemPrompt,
            user: instructions + finalPromptPreamble + fitted.text)
    }

    // MARK: 预算装配

    /// 会议过长、裁剪后仍无法在预算内完成时的可读错误（UI 直接展示）。
    enum MinutesError: LocalizedError {
        case transcriptTooLong(estimatedNotesTokens: Int, inputBudget: Int)

        var errorDescription: String? {
            switch self {
            case .transcriptTooLong(let estimated, let budget):
                return "This meeting is too long for the configured context window "
                    + "(~\(estimated) tokens of notes vs. a \(budget)-token input budget). "
                    + "Raise the context window in Settings or split the recording."
            }
        }
    }

    /// 最终提交模板的固定文本（预算须扣除）。
    private static let finalPromptPreamble = "\n\nThe meeting transcript was too long to process "
        + "at once; below are sequential notes extracted from each part. Write the minutes from "
        + "these notes.\n\nNotes:\n"

    /// 单次直通模板的固定标签。
    private static let transcriptLabel = "\n\nTranscript:\n"

    /// 预算余量（角色分隔/JSON 包装等未计入的零头）。
    private static let budgetSlackTokens = 16

    /// 把单段文本压进 token 预算：超限则保留**开头与结尾**（60%/40%），
    /// 中间以省略标记替代——会议的关键结论/行动项常出现在段尾，只留开头
    /// 会丢掉最重要的信息。
    ///
    /// 按字符裁剪即可满足 token 预算：估计器里 CJK 1 字符 = 1 token、
    /// 其余 3 字符 = 1 token，故「字符数 ≤ budget」必然「估计 token ≤ budget」。
    static func clipToBudget(_ text: String, budget: Int) -> String {
        guard budget > 0 else { return "" }
        guard text.count > budget else { return text }
        guard budget > truncationMarker.count + 8 else {
            return String(text.prefix(budget))
        }
        let remaining = budget - truncationMarker.count
        let headCount = remaining * 3 / 5
        let tailCount = remaining - headCount
        return String(text.prefix(headCount)) + truncationMarker + String(text.suffix(tailCount))
    }

    /// 截断标记（长度计入预算）。
    private static let truncationMarker = "\n[… truncated …]\n"

    /// 在预算内装配最终 notes。
    /// - Returns: (文本, 是否发生截断)；nil = 预算过小，无法产出有意义的纪要
    ///   （调用方抛 `MinutesError.transcriptTooLong`，给出可读错误而不是让
    ///   请求超限失败）。
    static func fitNotesToBudget(_ notes: [String], budget: Int)
        -> (text: String, truncated: Bool)? {
        guard !notes.isEmpty else { return nil }
        let joined = notes.joined(separator: "\n\n")
        if estimatedTokens(joined) <= budget { return (joined, false) }

        // 每段均分配额（扣除 "\n\n" 分隔符 2 字符）：让每一段都保留首尾，
        // 而不是「前面的段全留、后面的段全丢」。
        let perNoteBudget = budget / notes.count - 2
        // 每段至少要装下截断标记 + 一点上下文，否则无法产出有意义的纪要。
        guard perNoteBudget >= truncationMarker.count + 64 else { return nil }
        let fitted = notes.map { clipToBudget($0, budget: perNoteBudget) }
        let text = fitted.joined(separator: "\n\n")
        // 双保险：逐段配额之和必须落在预算内（估计器上界已保证，这里兜底）。
        guard estimatedTokens(text) <= budget else { return nil }
        return (text, true)
    }

    // MARK: Token estimation & chunking

    /// Rough token count: CJK characters ≈ 1 token each, everything else ≈ 3
    /// characters per token. Deliberately overestimates so chunks stay safely
    /// inside the context window.
    static func estimatedTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF,     // CJK radicals, kana, CJK unified
                 0xAC00...0xD7AF,     // Hangul syllables
                 0xF900...0xFAFF,     // CJK compatibility
                 0xFF00...0xFFEF,     // full-width forms
                 0x20000...0x2FA1F:   // CJK extensions
                cjk += 1
            default:
                other += 1
            }
        }
        return cjk + other / 3
    }

    /// Greedily pack lines into chunks of at most `budget` estimated tokens.
    /// A single line longer than the budget becomes its own chunk (transcript
    /// segments are short, so this is a safety valve, not an expected path).
    static func chunk(lines: [String], budget: Int) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0
        for line in lines {
            let tokens = estimatedTokens(line) + 1
            if !current.isEmpty, currentTokens + tokens > budget {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentTokens = 0
            }
            current.append(line)
            currentTokens += tokens
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }

    // MARK: Chat call

    /// One chat-completion round-trip using the OpenAI API settings shared with
    /// translation (endpoint / key / model UserDefaults keys).
    private static func chat(system: String, user: String) async throws -> String {
        let endpoint = (UserDefaults.standard.string(forKey: "translationEndpoint") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = UserDefaults.standard.string(forKey: "translationAPIKey") ?? ""
        let model = (UserDefaults.standard.string(forKey: "translationModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TranslationError.unavailable
        }

        // 端点可能带查询串（Azure 风格 `?api-version=...`）：用 URLComponents
        // 改 path，字符串拼接会把路径拼进 query 导致请求失败。
        let baseURL = TranslationService.chatCompletionsURL(
            endpoint.isEmpty ? "https://api.openai.com/v1" : endpoint)
        guard let url = URL(string: baseURL) else {
            throw TranslationError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Minutes responses are long-form; allow far more time than translation.
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": model.isEmpty ? "gpt-4o-mini" : model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await TranslationService.performRequestWithRetry(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.parseError
        }
        return stripCodeFences(content)
    }

    /// Models sometimes wrap output in ``` fences despite instructions; unwrap them.
    static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("```") else { return result }
        if let newline = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: newline)...])
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Minutes Generator (UI state)

/// Main-actor state for the Meeting Minutes window: the current generation
/// task, its phase, and the produced HTML. A singleton because the app has a
/// single minutes window; a new generation replaces the previous result.
@MainActor
@Observable
final class MinutesGenerator {
    static let shared = MinutesGenerator()

    enum Phase: Equatable {
        case idle
        case generating(String)   // human-readable progress status
        case completed
        case failed(String)
    }

    var phase: Phase = .idle
    /// The generated minutes as an HTML fragment (body content only).
    var htmlFragment: String = ""
    var itemName: String = ""
    var promptName: String = ""
    /// The transcription item the current minutes belong to.
    var sourceItemID: UUID?

    private var task: Task<Void, Never>?
    /// Identifies the current generation so a superseded task's late progress
    /// or result can't clobber the newer one.
    private var generation = UUID()

    private init() {}

    /// A complete, self-contained HTML document for the webview / export.
    var fullHTMLDocument: String {
        Self.wrapHTML(fragment: htmlFragment, title: itemName.isEmpty ? "Meeting Minutes" : itemName)
    }

    func generate(item: TranscriptionItem, prompt: MinutesPrompt) {
        task?.cancel()
        itemName = item.fileName
        promptName = prompt.name
        sourceItemID = item.id
        htmlFragment = ""
        phase = .generating("Preparing transcript…")

        let lines: [String]
        if item.segments.isEmpty {
            lines = item.fullText
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else {
            lines = item.segments.map { seg in
                "[\(Self.formatTimestamp(seg.start))] \(seg.text.trimmingCharacters(in: .whitespaces))"
            }
        }
        guard !lines.isEmpty else {
            phase = .failed("The transcript is empty.")
            return
        }

        let instructions = prompt.prompt
        let contextTokens = MinutesPromptStore.contextTokens()
        let token = UUID()
        generation = token

        task = Task { [weak self] in
            do {
                let fragment = try await MeetingMinutesService.generateMinutes(
                    transcriptLines: lines,
                    instructions: instructions,
                    contextTokens: contextTokens
                ) { [weak self] status in
                    guard let self, self.generation == token else { return }
                    self.phase = .generating(status)
                }
                guard let self, self.generation == token else { return }
                self.htmlFragment = fragment
                self.phase = .completed
            } catch is CancellationError {
                // Superseded or cancelled — the new generation owns the phase.
            } catch {
                guard let self, self.generation == token else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .generating = phase { phase = .idle }
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: HTML shell

    static func wrapHTML(fragment: String, title: String) -> String {
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapedTitle)</title>
        <style>
        :root { color-scheme: light dark; }
        body {
            font-family: -apple-system, "Helvetica Neue", "PingFang TC", "Hiragino Sans", sans-serif;
            line-height: 1.6;
            max-width: 46em;
            margin: 0 auto;
            padding: 2em 1.6em 3em;
            color: #1d1d1f;
            background: #ffffff;
        }
        h1 { font-size: 1.55em; margin: 0 0 0.6em; padding-bottom: 0.35em; border-bottom: 2px solid #d2d2d7; }
        h2 { font-size: 1.15em; margin: 1.6em 0 0.5em; }
        h3 { font-size: 1.0em; margin: 1.2em 0 0.4em; }
        p { margin: 0.5em 0; }
        ul, ol { margin: 0.4em 0 0.8em; padding-left: 1.6em; }
        li { margin: 0.25em 0; }
        table { border-collapse: collapse; width: 100%; margin: 0.8em 0 1.2em; font-size: 0.95em; }
        th, td { border: 1px solid #d2d2d7; padding: 6px 10px; text-align: left; vertical-align: top; }
        th { background: #f5f5f7; font-weight: 600; }
        blockquote { margin: 0.6em 0; padding: 0.2em 1em; border-left: 3px solid #d2d2d7; color: #6e6e73; }
        @media (prefers-color-scheme: dark) {
            body { color: #e8e8ed; background: #1e1e1e; }
            h1 { border-bottom-color: #48484a; }
            th, td { border-color: #48484a; }
            th { background: #2c2c2e; }
            blockquote { border-left-color: #48484a; color: #98989d; }
        }
        </style>
        </head>
        <body>
        \(fragment)
        </body>
        </html>
        """
    }
}
