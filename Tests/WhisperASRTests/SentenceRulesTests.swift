import XCTest
@testable import WhisperASR

/// 多语言分句规则（移植 yasbd 17 语言母语规则）回归：
/// 各语言句末标点、小数/缩写保护、泰语无标点回退、脚本检测。
final class SentenceRulesTests: XCTestCase {

    private func makeDetector() -> SpeechEndpointDetector {
        SpeechEndpointDetector(config: SpeechEndpointConfig())
    }

    private func assertSentenceEnded(_ text: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        var detector = makeDetector()
        let event = detector.update(text: text)
        guard case .sentenceEnded = event else {
            return XCTFail("应成句：\(text) → 实际 \(event)", file: file, line: line)
        }
    }

    private func assertNotEnded(_ text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        var detector = makeDetector()
        let event = detector.update(text: text)
        if case .sentenceEnded = event {
            XCTFail("不应成句：\(text)", file: file, line: line)
        }
    }

    // MARK: 各语言句末标点

    func testChineseTerminator() { assertSentenceEnded("今天天气很好。") }
    func testJapaneseTerminator() { assertSentenceEnded("ありがとうございました。") }
    func testKoreanTerminator() { assertSentenceEnded("안녕하세요.") }
    func testEnglishTerminator() { assertSentenceEnded("Hello world.") }
    func testRussianTerminator() { assertSentenceEnded("Привет мир.") }
    func testGreekQuestionMark() {
        // 希腊语「;」是问号（ANO TELEIA 语义）→ 终止。
        assertSentenceEnded("Τι κάνεις;")
    }
    func testArabicQuestionMark() { assertSentenceEnded("كيف حالك؟") }
    func testUrduFullStop() { assertSentenceEnded("آپ کیسے ہیں۔") }
    func testDevanagariDanda() { assertSentenceEnded("नमस्ते दुनिया।") }
    func testArmenianFullStop() { assertSentenceEnded("Բարև աշխարհ։") }
    func testEthiopicFullStop() { assertSentenceEnded("ሰላም ዓለም።") }
    func testExclamationAcrossScripts() { assertSentenceEnded("Hello!") }

    // MARK: 小数保护（拉丁/西里尔句点）

    func testDecimalNotEnded() {
        // 「3.」流式未决（句点前是数字且为末字符）→ 不立即断。
        assertNotEnded("圆周率约为 3.")
    }

    func testDecimalGrowthNotEnded() {
        var detector = makeDetector()
        _ = detector.update(text: "圆周率约为 3.")
        let event = detector.update(text: "圆周率约为 3.14")
        // last 是数字，非终止符——既不成句也不应误报。
        if case .sentenceEnded = event { XCTFail("小数不应断句") }
    }

    func testCJKPeriodUnaffected() {
        // 中文句号无小数歧义：数字后的「。」仍断句。
        assertSentenceEnded("得分是 3。")
    }

    // MARK: 缩写保护

    func testAbbreviationNotEnded() {
        assertNotEnded("会由 Dr.")
    }

    func testAbbreviationThenRealTerminator() {
        var detector = makeDetector()
        _ = detector.update(text: "会由 Dr.")
        let event = detector.update(text: "会由 Dr. Smith 主持.")
        guard case .sentenceEnded = event else {
            return XCTFail("缩写后续真实句点应成句，实际：\(event)")
        }
    }

    // MARK: 泰语无标点（回退 VAD/长度）

    func testThaiNoPunctuationFallsBack() {
        // 泰文无句末标点：任何字符结尾都不成句，靠长度/VAD 兜底。
        assertNotEnded("สวัสดีครับยินดีที่ได้รู้จัก")
    }

    func testThaiLengthFallbackStillWorks() {
        var detector = makeDetector()
        let longThai = Array(repeating: "สวัสดี", count: 20).joined()
        let event = detector.update(text: longThai)
        guard case .sentenceEnded = event else {
            return XCTFail("泰文超长文本应由长度兜底断句，实际：\(event)")
        }
    }

    // MARK: 脚本检测

    func testScriptDetection() {
        XCTAssertEqual(SentenceScript.detect("hello"), .latin)
        XCTAssertEqual(SentenceScript.detect("Привет"), .cyrillic)
        XCTAssertEqual(SentenceScript.detect("Καλημέρα"), .greek)
        XCTAssertEqual(SentenceScript.detect("مرحبا"), .arabic)
        XCTAssertEqual(SentenceScript.detect("שלום"), .hebrew)
        XCTAssertEqual(SentenceScript.detect("नमस्ते"), .devanagari)
        XCTAssertEqual(SentenceScript.detect("Բարև"), .armenian)
        XCTAssertEqual(SentenceScript.detect("ሰላም"), .ethiopic)
        XCTAssertEqual(SentenceScript.detect("สวัสดี"), .thaiLaoMyanmar)
        XCTAssertEqual(SentenceScript.detect("你好"), .cjk)
        XCTAssertEqual(SentenceScript.detect("안녕"), .korean)
        XCTAssertEqual(SentenceScript.detect("123"), .mixed)
    }

    func testLatinDigitsDoNotMaskScript() {
        // 拉丁字母 + 数字混合 → latin（数字不参与脚本判定）。
        XCTAssertEqual(SentenceScript.detect("abc 123"), .latin)
    }

    // MARK: 规则覆盖（自定义 terminators 仍可用）

    func testCustomTerminatorOverride() {
        var detector = SpeechEndpointDetector(
            config: SpeechEndpointConfig(sentenceTerminators: ["|"]))
        _ = detector.update(text: "自定义规则一")
        guard case .sentenceEnded = detector.update(text: "自定义规则一|") else {
            return XCTFail("自定义终止符应生效")
        }
    }
}
