import Foundation

// MARK: - 字幕语言判定（区分俄语西里尔 / 中文宽度，不混用等宽计数）

enum SubtitleLanguage {
    case russian
    case chinese
    case other

    /// 单行最大字符数：俄语 44（含空格标点），中文 26 字。
    var maxCharsPerLine: Int {
        switch self {
        case .russian, .other: return 44
        case .chinese: return 26
        }
    }

    static func detect(_ text: String) -> SubtitleLanguage {
        let scalars = text.unicodeScalars
        if scalars.contains(where: Self.isCyrillic) { return .russian }
        if scalars.contains(where: Self.isCJK) { return .chinese }
        return .other
    }

    static func isCyrillic(_ s: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(s.value) || (0x0500...0x052F).contains(s.value)
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
            || (0x3000...0x303F).contains(s.value) || (0xFF00...0xFFEF).contains(s.value)
    }
}

// MARK: - 字幕状态机（Idle / Listening / Recognizing / Translating / Showing）

enum SubtitleState: String, Equatable {
    /// 无会话。
    case idle
    /// 监听中：无语音或不足最短识别时长（不显示）。
    case listening
    /// 识别中：实时显示正在说的话（逐字/逐词更新）。
    case recognizing
    /// 一句结束，翻译请求进行中（仍显示原文）。
    case translating
    /// 翻译完成显示（或失败回退原文）。
    case showing
}

// MARK: - 字幕链路调试开关
//
// 排查用（默认关闭，不影响正常行为）：
// bypassFilters = true 时，ViewModel 绕过句子端点/最短时长/去重过滤，
// 任何非空 ASR 文本直接渲染显示（先恢复"任何文字立即显示"，再逐个排查过滤）。

enum SubtitleDebug {
    static var bypassFilters = false
}

// MARK: - 句子端点检测（SpeechEndpointDetector）

struct SpeechEndpointConfig {
    /// 标点结束符（文字级断句；音频切片/停顿判定由 AudioManager 负责）。
    var sentenceTerminators: Set<Character> = ["。", "？", "！", ".", "?", "!"]
}

enum SpeechEndpointEvent: Equatable {
    case none
    /// 实时识别文本更新（可显示）。
    case recognized(String)
    /// 一句结束（标点），携带完整句子。
    case sentenceEnded(String)
}

/// 句子端点检测：仅文字级标点断句。
/// 音频切片 / 发送时机 / 停顿判定由 AudioManager 负责，本检测器不再等待音频时长。
struct SpeechEndpointDetector {
    var config: SpeechEndpointConfig

    private(set) var sentenceText = ""
    /// 最近已结束的句子：避免标点结束后 whisper 重复推同一文本再次触发翻译。
    private var lastEndedText = ""

    init(config: SpeechEndpointConfig = SpeechEndpointConfig()) {
        self.config = config
    }

    mutating func update(text: String) -> SpeechEndpointEvent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        // 句点后重复推送旧文本：忽略；前缀延续则把新内容作为下一句起点。
        if !lastEndedText.isEmpty {
            if trimmed == lastEndedText {
                return .none
            }
            if trimmed.hasPrefix(lastEndedText) {
                let remainder = trimmed.dropFirst(lastEndedText.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !remainder.isEmpty else { return .none }
                lastEndedText = ""
                return startSentence(remainder)
            }
        }

        if sentenceText.isEmpty {
            return startSentence(trimmed)
        }

        sentenceText = trimmed

        // 标点结束：。？！.?! 等。
        if let last = trimmed.last, config.sentenceTerminators.contains(last) {
            return endSentence()
        }
        return .recognized(trimmed)
    }

    private mutating func startSentence(_ text: String) -> SpeechEndpointEvent {
        sentenceText = text
        return .recognized(text)
    }

    private mutating func endSentence() -> SpeechEndpointEvent {
        let text = sentenceText
        lastEndedText = text
        reset()
        return .sentenceEnded(text)
    }

    mutating func reset() {
        sentenceText = ""
    }
}

// MARK: - 字幕分割（核心）

/// 按语言宽度把长文本拆成最多 2 行：
/// - 俄语：44 字符/行，只在空格、逗号处换行，禁止切断单词；
/// - 中文：26 字/行，优先在标点（逗号等）后换行，无标点时按字硬切；
/// - 超过 2 行时截断前端内容，只保留末尾两行。
enum SubtitleSplitter {
    static let maxLines = 2

    static func split(text: String) -> [String] {
        split(text: text, language: SubtitleLanguage.detect(text))
    }

    static func split(text: String, language: SubtitleLanguage) -> [String] {
        Array(wrapAllLines(text: text, language: language).suffix(maxLines))
    }

    /// 返回全部换行后的行（不截断），供滚动渲染使用；保留文本内已有 \n。
    static func wrapAllLines(text: String, language: SubtitleLanguage) -> [String] {
        var result: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            result.append(contentsOf: wrapSingleLine(rawLine, language: language))
        }
        return result
    }

    /// 单段文本的贪心断行：优先在最近空格/逗号/标点后断行，不硬切俄语单词。
    private static func wrapSingleLine(_ text: String, language: SubtitleLanguage) -> [String] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }

        let maxChars = language.maxCharsPerLine
        // 断行机会：中文在标点/逗号后，俄语在空格/逗号后（词边界）。
        let breakChars: Set<Character> = language == .chinese
            ? ["，", "。", "、", "；", "：", "！", "？", ",", ".", ";", "!", "?", " "]
            : [" ", ","]

        var lines: [String] = []
        var line = ""
        var lastBreak = -1 // 当前行内最后一个可断点字符的下标（断在该字符之后）

        for ch in chars {
            line.append(ch)
            if breakChars.contains(ch) {
                lastBreak = line.count - 1
            }
            guard line.count >= maxChars else { continue }

            if lastBreak > 0 {
                // 在最近一次空格/逗号/标点后断行，优先词边界、不硬切。
                let cut = line.index(line.startIndex, offsetBy: lastBreak + 1)
                lines.append(String(line[..<cut]).trimmingCharacters(in: .whitespaces))
                line = String(line[cut...]).trimmingCharacters(in: .whitespaces)
                lastBreak = -1
            } else if language != .russian {
                // 中文无标点可断：按字硬切（汉字原子不可再分）。
                lines.append(line)
                line = ""
                lastBreak = -1
            }
            // 俄语当前行无断点 = 单个超长单词：不切断单词，继续累积，
            // 由视图在固定宽度内视觉换行兜底（宁可超限也不切词）。
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }
}

// MARK: - 增量字幕缓冲（Streaming Subtitle Buffer）

/// 增量合并 ASR 实时返回的 chunk，避免每次整体替换字幕：
/// - 新文本以旧文本为前缀（稳定追加）→ 返回追加段，保留已显示前缀；
/// - 完全相同 → noChange（不刷新，防抖动/跳字）；
/// - 分歧（ASR 回溯修正）→ replaced（整体替换）。
enum SubtitleBufferMerge: Equatable {
    case noChange
    case appended(String)
    case replaced
}

final class StreamingSubtitleBuffer {
    private(set) var text = ""

    func merge(_ newText: String) -> SubtitleBufferMerge {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text else { return .noChange }
        if text.isEmpty {
            text = trimmed
            return .appended(trimmed)
        }
        if trimmed.hasPrefix(text) {
            let suffix = String(trimmed.dropFirst(text.count))
            text = trimmed
            return .appended(suffix)
        }
        text = trimmed
        return .replaced
    }

    func reset() {
        text = ""
    }
}

// MARK: - 智能断句（SubtitleSentenceSplitter）

/// 把连续 ASR 文本拆成可显示的单句（断句规则见需求六/七）：
/// - 中文单句上限 30 字，优先在 ，。！？； 处断；
/// - 英文单句上限 80 字符，优先在 ,.!?; 处断，无标点按最大长度切，绝不从单词中间切断；
/// - 阈值可配置（设置页同步）。
struct SubtitleSentenceSplitter {
    var maxChineseChars: Int = 30
    var maxEnglishChars: Int = 80

    /// 返回句块列表；文本内已有 \n 视为强制断句。
    func split(_ text: String, language: SubtitleLanguage) -> [String] {
        var result: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            result.append(contentsOf: splitLine(rawLine, language: language))
        }
        return result
    }

    private func splitLine(_ text: String, language: SubtitleLanguage) -> [String] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }

        let maxChars = language == .chinese ? maxChineseChars : maxEnglishChars
        // 断句机会：中文标点 + 空格/逗号；英文标点 + 空格（词边界，不切词）。
        let breakChars: Set<Character> = language == .chinese
            ? ["，", "。", "！", "？", "；", "、", ",", ".", "!", "?", ";", " "]
            : [",", ".", "!", "?", ";", " ", "，", "。", "！", "？", "；"]

        var lines: [String] = []
        var line = ""
        var lastBreak = -1

        for ch in chars {
            line.append(ch)
            if breakChars.contains(ch) {
                lastBreak = line.count - 1
            }
            guard line.count >= maxChars else { continue }

            if lastBreak > 0 {
                // 在最近标点/空格后断句（英文保持在单词边界）。
                let cut = line.index(line.startIndex, offsetBy: lastBreak + 1)
                lines.append(String(line[..<cut]).trimmingCharacters(in: .whitespaces))
                line = String(line[cut...]).trimmingCharacters(in: .whitespaces)
                lastBreak = -1
            } else if language == .chinese {
                // 中文无标点可断：按字硬切（汉字原子不可再分）。
                lines.append(line)
                line = ""
                lastBreak = -1
            }
            // 英文无断点 = 单个超长单词：不切断，交由视图按宽度换行兜底。
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }
}

// MARK: - 字幕去重（SubtitleDeduplicator）

enum DedupeDecision: Equatable {
    /// 与近期字幕相同/回溯（重复输出）：不刷新。
    case suppress
    /// 新字幕是旧字幕的延续（前缀增长）：合并显示，正常刷新。
    case merge
    /// 全新内容：正常刷新。
    case refresh
}

/// 对比最近字幕，解决 ASR 重复输出 / 跳字：
/// - 完全相同 → suppress（不刷新）；
/// - 新文本以旧文本开头（增量延续）→ merge（合并显示，不重复成两条）；
/// - 新文本是旧文本的短前缀（ASR 回溯）→ suppress；
/// - 其余 → refresh。
final class SubtitleDeduplicator {
    private struct Entry {
        let text: String
        let date: Date
    }

    private var entries: [Entry] = []
    let window: TimeInterval
    /// 硬上限：同一窗口内最多保留 50 条（环形），防极端高频输入内存增长。
    private let maxEntries = 50

    init(window: TimeInterval = 8) {
        self.window = window
    }

    func decide(_ text: String, now: Date = Date()) -> DedupeDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .suppress }
        prune(now: now)
        guard let last = entries.last else { return .refresh }
        // 近期窗口内出现相同文本：重复输出，抑制刷新。
        if entries.contains(where: { $0.text == trimmed }) {
            return .suppress
        }
        // 新文本以旧文本开头：增量延续，合并显示。
        if trimmed.hasPrefix(last.text) {
            return .merge
        }
        // 新文本是旧文本的短前缀：ASR 回溯，抑制刷新。
        if last.text.hasPrefix(trimmed), trimmed.count < last.text.count {
            return .suppress
        }
        return .refresh
    }

    func record(_ text: String, now: Date = Date()) {
        prune(now: now)
        entries.append(Entry(text: text, date: now))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func reset() {
        entries.removeAll()
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.date) > window }
    }
}

// MARK: - 字幕延迟统计（SubtitleLatencyManager）

/// 统计实时字幕链路延迟：ASR 到达 → 翻译完成 → 显示提交。
/// 目标：实时字幕延迟 < 2 秒。
final class SubtitleLatencyManager {
    private var inputArrivedAt: Date?
    private var translatedAt: Date?

    private(set) var lastTranslationMs = 0
    private(set) var lastDisplayMs = 0
    private(set) var lastTotalMs = 0

    func markInput() {
        inputArrivedAt = Date()
        translatedAt = nil
    }

    func markTranslated() {
        guard let input = inputArrivedAt else { return }
        translatedAt = Date()
        lastTranslationMs = Int(translatedAt!.timeIntervalSince(input) * 1000)
    }

    func markDisplayed() {
        guard let input = inputArrivedAt else { return }
        let now = Date()
        lastDisplayMs = Int(now.timeIntervalSince(input) * 1000)
        lastTotalMs = lastDisplayMs
    }

    func reset() {
        inputArrivedAt = nil
        translatedAt = nil
        lastTranslationMs = 0
        lastDisplayMs = 0
        lastTotalMs = 0
    }
}

// MARK: - 字幕处理器（SubtitleProcessor）

/// 统一字幕处理管线：ASR / 翻译输出都必须经过这里。
/// ASR → 语言检测 → 翻译（可选） → 断句 → 去重 → 长度控制 → 缓冲 → 显示策略。
///
/// 维护：
/// - `temporarySubtitle`：当前流式句子（未确认，实时增长）；
/// - `confirmedSubtitle`：最近一句完整句；
/// - 显示缓存最多 2 句（第三句直接丢弃，不交给 SwiftUI 截断）。
final class SubtitleProcessor {
    let splitter = SubtitleSentenceSplitter()
    let deduplicator = SubtitleDeduplicator()
    let latency = SubtitleLatencyManager()

    private(set) var temporarySubtitle = ""
    private(set) var confirmedSubtitle = ""
    private var confirmedSentences: [String] = []
    private let maxSentences = 2

    struct Result: Equatable {
        /// 最终展示行（≤2 句）。
        let lines: [String]
        /// 是否有内容变化（false = 不刷新）。
        let changed: Bool
        /// 是否被去重抑制（重复/回溯）。
        let suppressed: Bool
    }

    /// 喂入最新 ASR 文本（interim）；返回展示行与刷新决策。
    func ingest(asrText: String) -> Result {
        latency.markInput()
        let trimmed = asrText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            temporarySubtitle = ""
            let lines = displayLines()
            latency.markDisplayed()
            return Result(lines: lines, changed: false, suppressed: false)
        }

        switch deduplicator.decide(trimmed) {
        case .suppress:
            latency.markDisplayed()
            return Result(lines: displayLines(), changed: false, suppressed: true)
        case .merge, .refresh:
            temporarySubtitle = trimmed
            deduplicator.record(trimmed)
        }

        // 断句：超过阈值/出现标点 → 完整句进入 confirmed，末句留在临时。
        let sentences = splitter.split(temporarySubtitle, language: SubtitleLanguage.detect(temporarySubtitle))
        if sentences.count > 1 {
            confirmedSentences = Array((confirmedSentences + sentences.dropLast()).suffix(maxSentences))
            temporarySubtitle = sentences.last ?? ""
            confirmedSubtitle = confirmedSentences.last ?? ""
        }

        let lines = displayLines()
        latency.markDisplayed()
        return Result(lines: lines, changed: true, suppressed: false)
    }

    /// 收到确认句（final 段落）时同步：若与当前临时字幕相同则确认它。
    func confirmFinal(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if temporarySubtitle.hasSuffix(trimmed) || temporarySubtitle == trimmed {
            temporarySubtitle = ""
        }
        confirmedSentences = Array((confirmedSentences + [trimmed]).suffix(maxSentences))
        confirmedSubtitle = confirmedSentences.last ?? ""
    }

    /// 当前展示行：confirmed + temporary，最多 2 句。
    private func displayLines() -> [String] {
        var result = confirmedSentences
        if !temporarySubtitle.isEmpty {
            result.append(temporarySubtitle)
        }
        return Array(result.suffix(maxSentences))
    }

    func reset() {
        temporarySubtitle = ""
        confirmedSubtitle = ""
        confirmedSentences = []
        deduplicator.reset()
        latency.reset()
    }
}

// MARK: - 字幕渲染器（SubtitleRenderer）

/// 显示状态容器：由 SubtitleProcessor 输出填充，最多 maxLines 行。
/// 只承载文本内容（不创建窗口实例），配合 withAnimation 平滑刷新。
struct SubtitleRenderer {
    var maxLines: Int
    private(set) var lines: [String] = []
    private(set) var text = ""

    /// 设置展示行；与上次相同返回 false（调用方不刷新）。
    @discardableResult
    mutating func setLines(_ newLines: [String]) -> Bool {
        let capped = Array(newLines.prefix(max(maxLines, 1)))
        guard capped != lines else { return false }
        lines = capped
        text = capped.joined(separator: "\n")
        return true
    }

    mutating func clear() {
        text = ""
        lines = []
    }
}

// MARK: - 字幕历史缓存（SubtitleHistoryBuffer）

/// 保存最近 5–10 秒的字幕文本，用于去重（相同字幕不刷新）、平滑刷新、防跳字。
final class SubtitleHistoryBuffer {
    private struct Entry {
        let text: String
        let date: Date
    }

    private var entries: [Entry] = []
    let window: TimeInterval

    init(window: TimeInterval = 8) {
        self.window = window
    }

    /// 窗口内是否没有重复文本（true = 可以刷新）。
    func shouldRefresh(_ text: String, now: Date = Date()) -> Bool {
        prune(now: now)
        return !entries.contains { $0.text == text }
    }

    func record(_ text: String, now: Date = Date()) {
        prune(now: now)
        entries.append(Entry(text: text, date: now))
    }

    func reset() {
        entries.removeAll()
    }

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.date) > window }
    }
}

// MARK: - 字幕三层队列（调度核心）

/// 一条字幕（已分割为 ≤2 行文本，行间用 \n 分隔）。
struct SubtitleQueueEntry: Identifiable, Equatable {
    let id: String
    let text: String
    let translation: String?
    let createdAt: Date
}

/// 三层固定槽位队列：
///   history（顶部，最旧）→ previous（左上，上一条）→ latest（右下，最新实时）
///
/// 调度规则：
/// 1. 新字幕抵达：立即清除顶部历史（不做缓慢淡出），原左上降级为历史，
///    原右下升为左上，新字幕放入右下——三层即上限，被顶掉的旧历史就是
///    被丢弃的最早字幕；
/// 2. 历史层存活时长最短，由调用方按超时调用 `expireHistory` 直接销毁。
struct SubtitleQueue: Equatable {
    private(set) var history: SubtitleQueueEntry?
    private(set) var previous: SubtitleQueueEntry?
    private(set) var latest: SubtitleQueueEntry?

    var count: Int {
        (history != nil ? 1 : 0) + (previous != nil ? 1 : 0) + (latest != nil ? 1 : 0)
    }

    /// 推入新字幕，返回被立即销毁的旧历史 id（nil 表示之前没有历史）。
    @discardableResult
    mutating func push(_ entry: SubtitleQueueEntry) -> String? {
        let droppedID = history?.id
        history = previous
        previous = latest
        latest = entry
        return droppedID
    }

    /// 历史层超时销毁（存活时长最短）。返回是否真的销毁了历史。
    @discardableResult
    mutating func expireHistory(now: Date = Date(), lifetime: TimeInterval) -> Bool {
        guard let h = history, now.timeIntervalSince(h.createdAt) > lifetime else { return false }
        history = nil
        return true
    }
}
