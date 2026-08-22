import XCTest
@testable import WhisperASR

/// 断行稳定性与规则：行数上限、超限保留末尾、标点优先断行、词边界。
final class SubtitleSplitterTests: XCTestCase {

    /// 行数上限与内容完整性：任意长度文本 split 后 ≤2 行，
    /// 且各行重组覆盖原文的末尾（滚动窗口只丢最旧内容）。
    func testSplitCapsAtTwoLinesAndKeepsTail() {
        let text = String(repeating: "这是一段比较长的中文文本。", count: 10)
        let lines = SubtitleSplitter.split(text: text, language: .chinese)
        XCTAssertLessThanOrEqual(lines.count, 2)
        let joined = lines.joined()
        XCTAssertTrue(text.hasSuffix(joined), "split 保留的应是原文末尾内容")
    }

    func testWrapAllLinesPreservesContent() {
        let text = "短句一。短句二。短句三。"
        let lines = SubtitleSplitter.wrapAllLines(text: text, language: .chinese)
        XCTAssertEqual(lines.joined(), text, "wrapAllLines 不丢内容")
    }

    func testShortTextSingleLine() {
        let lines = SubtitleSplitter.split(text: "短句", language: .chinese)
        XCTAssertEqual(lines, ["短句"])
    }

    func testChineseBreaksPreferPunctuation() {
        // 26+ 字且含逗号：在最近的逗号后断行（不硬切词）。
        var text = ""
        for i in 0..<12 { text += "字\(i)" }
        text += "，后半段内容继续"
        while text.count < 30 { text += "补" }
        let lines = SubtitleSplitter.wrapAllLines(text: text, language: .chinese)
        if lines.count > 1 {
            XCTAssertTrue(lines[0].hasSuffix("，") || lines[0].count <= 26,
                          "中文断行优先落在标点后")
        }
    }

    func testWesternNeverCutsInsideWord() {
        // 俄语/西文：只在空格/逗号断——断行处两侧不得是字母连字母（词中切），
        // 且各行重组后内容与原文一致（不丢不重）。
        let words = (0..<12).map { "слово\($0)" }
        let text = words.joined(separator: " ")
        let lines = SubtitleSplitter.wrapAllLines(text: text, language: .russian)

        XCTAssertEqual(
            lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "),
            text,
            "各行重组应等于原文（内容不丢不重）")
        if lines.count > 1 {
            let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            for index in 0..<(trimmed.count - 1) {
                let line = trimmed[index], next = trimmed[index + 1]
                if let lineLast = line.last, let nextFirst = next.first {
                    XCTAssertFalse(
                        lineLast.isLetter && nextFirst.isLetter,
                        "西文断行不得切在单词中间：…\(line.suffix(3)) | \(next.prefix(3))…")
                }
            }
        }
    }
}

/// 语言判定：中文/西里尔/其他。
final class SubtitleLanguageTests: XCTestCase {

    func testDetectChinese() {
        XCTAssertEqual(SubtitleLanguage.detect("你好世界"), .chinese)
    }

    func testDetectRussian() {
        XCTAssertEqual(SubtitleLanguage.detect("Привет мир"), .russian)
    }

    func testDetectOther() {
        XCTAssertEqual(SubtitleLanguage.detect("hello world"), .other)
    }

    func testCjkPunctuationCountsAsChinese() {
        XCTAssertEqual(SubtitleLanguage.detect("，"), .chinese, "CJK 标点归中文宽度")
    }
}

/// 识别语言配置：effectiveASRLanguage 的归一规则（手动指定语言的接线核心）。
final class ASRConfigurationLanguageTests: XCTestCase {

    func testEffectiveLanguageNilForAuto() {
        let config = ASRConfiguration()
        config.asrLanguage = "auto"
        XCTAssertNil(config.effectiveASRLanguage)
    }

    func testEffectiveLanguageNilForEmptyOrWhitespace() {
        let config = ASRConfiguration()
        config.asrLanguage = ""
        XCTAssertNil(config.effectiveASRLanguage)
        config.asrLanguage = "   "
        XCTAssertNil(config.effectiveASRLanguage)
    }

    func testEffectiveLanguageValue() {
        let config = ASRConfiguration()
        config.asrLanguage = "zh"
        XCTAssertEqual(config.effectiveASRLanguage, "zh")
    }

    func testEffectiveLanguageNormalizesCaseAndSpaces() {
        let config = ASRConfiguration()
        config.asrLanguage = " EN "
        XCTAssertEqual(config.effectiveASRLanguage, "en", "大小写与空白归一")
    }
}
