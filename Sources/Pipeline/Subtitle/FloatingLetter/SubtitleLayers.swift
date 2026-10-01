import Foundation

// MARK: - 字幕语言判定（区分俄语西里尔 / 中文宽度，不混用等宽计数）

enum SubtitleLanguage {
    case russian
    case chinese
    case korean
    case other

    /// 单行最大字符数：俄语/西文 44（含空格标点），中文 26 字，
    /// 韩文 32（音节块信息密度略低于汉字，且带词间空格）。
    var maxCharsPerLine: Int {
        switch self {
        case .russian, .other: return 44
        case .chinese: return 26
        case .korean: return 32
        }
    }

    static func detect(_ text: String) -> SubtitleLanguage {
        let scalars = text.unicodeScalars
        if scalars.contains(where: Self.isCyrillic) { return .russian }
        if scalars.contains(where: Self.isHangul) { return .korean }
        if scalars.contains(where: Self.isCJK) { return .chinese }
        return .other
    }

    static func isCyrillic(_ s: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(s.value) || (0x0500...0x052F).contains(s.value)
    }

    /// 韩文：音节块（가-힣）+ 谚文字母（호환용）区段。
    static func isHangul(_ s: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(s.value)   // Hangul Syllables
            || (0x1100...0x11FF).contains(s.value)   // Jamo
            || (0x3130...0x318F).contains(s.value)   // Compatibility Jamo
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
    /// 标点结束符：默认 nil = 按 Unicode 脚本自动取多语言规则
    /// （SentenceRules：17+ 语言母语句末标点 + 小数/缩写保护）；
    /// 显式赋值则覆盖（测试/定制用）。
    var sentenceTerminators: Set<Character>? = nil
    /// 句内软断点：长度断句时优先在这些字符之后断开（不断在词中间）。
    var softBreakChars: Set<Character> = ["，", "、", "；", "：", ",", ";", " "]
    /// 长度兜底断句上限（字符数）：无标点、无停顿的连续语音（唱歌/朗读，
    /// VAD 断句不可用）超长时强制断句，防止字幕滚屏读不成句。
    /// 中文约一行（26 字/行），西文约 1.5 行。
    var maxSentenceLengthChinese = 28
    var maxSentenceLengthOther = 70
    /// 韩文长度兜底（音节块+空格，密度介于中日与西文之间）。
    var maxSentenceLengthKorean = 40
}

enum SpeechEndpointEvent: Equatable {
    case none
    /// 实时识别文本更新（可显示）。
    case recognized(String)
    /// 一句结束（标点 / 长度上限），携带完整句子。
    case sentenceEnded(String)
}

/// 句子端点检测：文字级断句（标点 + 长度兜底）。
/// 音频切片 / 发送时机 / 停顿（VAD）判定由 AudioManager / ASRManager 负责。
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

        // 本轮累积文本即当前句内容（首轮/后续均整段替换，上游保证 trimmed
        // 是"截至当前轮的完整累积文本"）。
        sentenceText = trimmed

        // 标点结束：多语言规则（SentenceRules 按脚本路由：
        // 。？！/./؟/।/։/።/；… + 小数与缩写保护）。
        // （首轮即完整句也在此检查——原实现 startSentence 分支提前返回，
        // 单轮完整带句号的句要等下一轮才成句；超长无标点句则完全绕过
        // 长度兜底，两者都是断句延迟/失效的真 bug。）
        let rules = config.sentenceTerminators.map { override in
            SentenceRules(terminators: override, decimalGuardedPeriod: false)
        } ?? SentenceRules.rules(for: trimmed)
        if rules.endsWithTerminator(trimmed) {
            return endSentence()
        }
        // 长度兜底：无标点、无停顿的连续语音超长时强制断句。
        let lengthLimit: Int
        switch SubtitleLanguage.detect(trimmed) {
        case .chinese: lengthLimit = config.maxSentenceLengthChinese
        case .korean: lengthLimit = config.maxSentenceLengthKorean
        case .russian, .other: lengthLimit = config.maxSentenceLengthOther
        }
        if trimmed.count >= lengthLimit {
            return endSentenceByLength()
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

    /// 长度断句：在后半句找最后一个软断点（逗号/顿号/空格）在其后断开，
    /// 找不到则硬切。已断部分作为完成句返回，剩余部分留作新句起点；
    /// lastEndedText 记录前缀，下一轮整体推送时自动衔接剩余部分。
    private mutating func endSentenceByLength() -> SpeechEndpointEvent {
        let chars = Array(sentenceText)
        let searchStart = chars.count / 2
        var cut = -1
        var i = chars.count - 1
        while i >= searchStart {
            if config.softBreakChars.contains(chars[i]) { cut = i; break }
            i -= 1
        }
        if cut < 0 { cut = chars.count - 1 }
        let ended = String(chars[...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(chars[(cut + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        lastEndedText = ended
        sentenceText = remainder
        return .sentenceEnded(ended)
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
///
/// 状态：**当前无可达生产调用点**——浮层渲染走 `SubtitleSentenceSplitter`
/// （中文 30 / 英文 80 字，见 FloatingLetterViewModel.renderText）。本类型
/// 保留是因为 SubtitleSplitterTests 的 13 个用例覆盖其断行规则，且
/// `wrapAllLines` 是滚动渲染的备选实现；接线前请先确认与
/// SubtitleSentenceSplitter 的取舍，避免两套断行规则并存。
enum SubtitleSplitter {
    static let maxLines = 2

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

// MARK: - 新句判定（SubtitleSentenceTrigger）
//
// 「final 队列末段是否代表新说的一句」的纯逻辑判据。抽成无状态结构体
// 便于单测（与 StreamingFeedWaterline / SentenceRules 同一路数）：
//
// 判据 = 「起点推进 or 文本变化」：
// - 起点推进（段起点在录制时间轴上单调前移）= 用户真的又说了一句，
//   即使文本与上一句完全相同（同一会话里重复同一句话）；
// - 文本变化（起点未变）= Apple 的 final 修正/封口；
// - 都不满足 = 静音轮询重复推送同一快照，不重复触发。
//
// 为什么不用「末段文本不同」单判据：上一句文本记录只在换会话时清空，
// 重复说同一句时第二次文本相同 → 永久静音（既不显示也不翻译）。
// 为什么不用「段数增长」：显示快照按 maxLiveSegments 环形裁剪，长会话
// 段数会饱和，判据随之失效。
struct SubtitleSentenceTrigger {
    /// 上一次已处理段的起点（录制时间轴秒）。
    private var lastStart: Double?
    /// 上一次已处理段的文本。
    private var lastText = ""

    /// 判定并记录。
    /// - Returns: true = 这是新说的一句，应对其触发显示/翻译。
    mutating func shouldTrigger(text: String, start: Double) -> Bool {
        let startAdvanced = lastStart.map { start > $0 } ?? true
        let textChanged = text != lastText
        guard startAdvanced || textChanged else { return false }
        lastStart = start
        lastText = text
        return true
    }

    /// 换会话重置（新会话第一句不受上一会话末句影响）。
    mutating func reset() {
        lastStart = nil
        lastText = ""
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

