import XCTest
@testable import WhisperASR

/// 断句器回归。调用模式与真实管线一致：每轮推送**完整累积文本**
///（ASRManager 的 pendingTail 是全量当前句，不是逐字 delta）。
/// 覆盖：标点断句、重复抑制、前缀衔接、长度兜底断句。
final class SpeechEndpointDetectorTests: XCTestCase {

    private func makeDetector() -> SpeechEndpointDetector {
        SpeechEndpointDetector(config: SpeechEndpointConfig())
    }

    // MARK: 标点断句

    func testPunctuationEndsSentenceOnGrowth() {
        var detector = makeDetector()
        _ = detector.update(text: "今天天气很好")                    // 增长轮：recognized
        let event = detector.update(text: "今天天气很好。")           // 出现句号：成句
        XCTAssertEqual(event, .sentenceEnded("今天天气很好。"))
    }

    func testSinglePassCompleteSentenceEndsImmediately() {
        var detector = makeDetector()
        // VAD 封口后引擎单轮推出完整带句号的句：当轮立即成句（不延迟）。
        let event = detector.update(text: "第一句完整带句号。")
        XCTAssertEqual(event, .sentenceEnded("第一句完整带句号。"))
    }

    func testRepeatAfterEndIsIgnored() {
        var detector = makeDetector()
        _ = detector.update(text: "句子。")
        // 静音封口后整句重推（回声）：忽略，不重复触发翻译。
        XCTAssertEqual(detector.update(text: "句子。"), .none)
    }

    func testContinuationAfterEndStartsNewSentence() {
        var detector = makeDetector()
        _ = detector.update(text: "第一句。")
        let event = detector.update(text: "第一句。第二句开始")
        XCTAssertEqual(event, .recognized("第二句开始"), "前缀延续把新内容作为下一句起点")
    }

    // MARK: 长度兜底断句（连续无停顿语音，如唱歌）

    func testChineseLengthFallbackCutsAtSoftBreak() {
        var detector = makeDetector()
        // 无句末标点；后半段含逗号软断点 → 超限后在最后一个逗号后断开。
        let text = "你陪我唱歌像一只，保护着我的家，我们是彼此有心的翅膀，勇敢飞翔"
        XCTAssertGreaterThanOrEqual(text.count, 28)
        let event = detector.update(text: text)
        guard case .sentenceEnded(let sentence) = event else {
            return XCTFail("中文 ≥28 字无句末标点应触发长度断句，实际：\(event)")
        }
        XCTAssertLessThanOrEqual(sentence.count, 28)
        XCTAssertTrue(sentence.hasSuffix("，") || sentence.hasSuffix("家"),
                      "应在后半段的软断点（逗号）后断开，实际结尾：\(sentence.suffix(2))")
        // 剩余部分留作新句起点（sentenceText 非空）。
        XCTAssertFalse(detector.sentenceText.isEmpty, "长度断句后剩余部分应留作新句")
    }

    func testChineseHardCutWhenNoSoftBreak() {
        var detector = makeDetector()
        // 30 个互不相同的汉字（无空格/逗号/标点）→ 无软断点硬切。
        let scalars: [Character] = (0..<30).map { i in
            Character(UnicodeScalar(0x4E00 + i * 7)!)   // 步进取字避开 CJK 标点区
        }
        let text = String(scalars)
        let event = detector.update(text: text)
        guard case .sentenceEnded(let sentence) = event else {
            return XCTFail("无软断点超限应硬切断句，实际：\(event)")
        }
        XCTAssertFalse(sentence.isEmpty)
    }

    func testEnglishLengthLimitUsesWesternThreshold() {
        var detector = makeDetector()
        // 西文阈值 70：60 字符不应断，75 字符应断。
        _ = detector.update(text: Array(repeating: "word ", count: 12).joined())
        XCTAssertGreaterThanOrEqual(detector.sentenceText.count, 55, "未达西文阈值不成句")
        let long = Array(repeating: "word ", count: 15).joined()
        let event = detector.update(text: long)
        guard case .sentenceEnded = event else {
            return XCTFail("西文 ≥70 字符应触发长度断句，实际：\(event)")
        }
    }

    func testShortTextWithoutPunctuationStaysRecognized() {
        var detector = makeDetector()
        XCTAssertEqual(detector.update(text: "还在说"), .recognized("还在说"))
    }

    func testEmptyTextIsIgnored() {
        var detector = makeDetector()
        XCTAssertEqual(detector.update(text: "   "), .none)
    }

    func testResetClearsCurrentSentence() {
        var detector = makeDetector()
        _ = detector.update(text: "说到一半")
        detector.reset()
        XCTAssertEqual(detector.update(text: "新句子"), .recognized("新句子"), "reset 后从零开始新句")
    }
}

/// 字幕去重：ASR 重复输出 / 回溯 / 增量延续的判定。
final class SubtitleDeduplicatorTests: XCTestCase {

    func testSameTextWithinWindowSuppresses() {
        let dedup = SubtitleDeduplicator(window: 8)
        dedup.record("相同句子")
        XCTAssertEqual(dedup.decide("相同句子"), .suppress, "窗口内相同文本应抑制")
    }

    func testPrefixGrowthMerges() {
        let dedup = SubtitleDeduplicator(window: 8)
        dedup.record("今天")
        XCTAssertEqual(dedup.decide("今天天气"), .merge, "前缀增长视为延续合并")
    }

    func testRegressionSuppresses() {
        let dedup = SubtitleDeduplicator(window: 8)
        dedup.record("完整的长句子")
        XCTAssertEqual(dedup.decide("完整的长"), .suppress, "新文本是旧文本短前缀 = ASR 回溯，抑制")
    }

    func testFreshTextRefreshes() {
        let dedup = SubtitleDeduplicator(window: 8)
        dedup.record("上一句")
        XCTAssertEqual(dedup.decide("另一句"), .refresh)
    }

    func testWindowExpiryAllowsRefresh() {
        let dedup = SubtitleDeduplicator(window: 0.05)
        let old = Date().addingTimeInterval(-1)
        dedup.record("句子", now: old)
        XCTAssertEqual(dedup.decide("句子"), .refresh, "窗口过期后相同文本不再抑制")
    }
}
