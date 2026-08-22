import XCTest
@testable import WhisperASR

/// 日韩语支持补丁回归：韩文语言分支（检测/断行宽度/长度兜底档位）
/// 与翻译输入 NFKC 归一化（全半角混排清洗）。
final class KoreanAndNormalizationTests: XCTestCase {

    // MARK: 韩文检测

    func testDetectKorean() {
        XCTAssertEqual(SubtitleLanguage.detect("안녕하세요 반갑습니다"), .korean)
    }

    func testDetectKoreanSyllableBlock() {
        // 单个音节块（区段边界：가 AC00 / 힣 D7A3）。
        XCTAssertEqual(SubtitleLanguage.detect("가"), .korean)
        XCTAssertEqual(SubtitleLanguage.detect("힣"), .korean)
    }

    func testChineseDetectionUnaffectedByKorean() {
        XCTAssertEqual(SubtitleLanguage.detect("你好世界"), .chinese)
        // 中韩混排：CJK 与 Hangul 并存时——检测顺序 Cyrillic→Hangul→CJK，
        // 韩文优先（韩文场景混入汉字概率高于中文场景混入韩文）。
        XCTAssertEqual(SubtitleLanguage.detect("漢字과 한글"), .korean)
    }

    func testKoreanLineWidth() {
        XCTAssertEqual(SubtitleLanguage.korean.maxCharsPerLine, 32)
        // 介于中文 26 与西文 44 之间。
        XCTAssertGreaterThan(SubtitleLanguage.korean.maxCharsPerLine,
                             SubtitleLanguage.chinese.maxCharsPerLine)
        XCTAssertLessThan(SubtitleLanguage.korean.maxCharsPerLine,
                          SubtitleLanguage.other.maxCharsPerLine)
    }

    // MARK: 韩文断行（词边界）

    func testKoreanWrapsAtSpacesNotInsideWords() {
        let words = (0..<14).map { "한국어\($0)" }
        let text = words.joined(separator: " ")
        let lines = SubtitleSplitter.wrapAllLines(text: text, language: .korean)
        // 韩文按西文断点（空格/逗号）断行：重组 = 原文，且不切词。
        XCTAssertEqual(lines.map { $0.trimmingCharacters(in: .whitespaces) }
                         .joined(separator: " "), text)
        if lines.count > 1 {
            let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            for index in 0..<(trimmed.count - 1) {
                let line = trimmed[index], next = trimmed[index + 1]
                if let last = line.last, let first = next.first {
                    XCTAssertFalse(last.isLetter && first.isLetter,
                                   "韩文断行不得切在词中间")
                }
            }
        }
    }

    // MARK: 韩文长度兜底档位

    func testKoreanLengthFallbackUsesKoreanThreshold() {
        var detector = SpeechEndpointDetector(config: SpeechEndpointConfig())
        // 40+ 韩文字符（无句末标点，含空格软断点）→ 韩文档位断句。
        let text = Array(repeating: "한국어 텍스트 ", count: 7).joined()
        XCTAssertGreaterThanOrEqual(text.count, 40)
        let event = detector.update(text: text)
        guard case .sentenceEnded = event else {
            return XCTFail("韩文 ≥40 字符应触发长度断句，实际：\(event)")
        }
    }

    // MARK: NFKC 翻译输入归一化

    func testNormalizeFullWidthDigitsAndLatin() {
        XCTAssertEqual(TranslationService.normalizeForTranslation("１２３ａｂｃ"), "123abc",
                       "全角数字/英数转半角标准形")
    }

    func testNormalizeFullWidthPunctuation() {
        XCTAssertEqual(TranslationService.normalizeForTranslation("你好！？"), "你好!?",
                       "全角标点归一为半角（翻译输入侧）")
    }

    func testNormalizeKeepsCJKIntact() {
        XCTAssertEqual(TranslationService.normalizeForTranslation("漢字한글"), "漢字한글",
                       "CJK 表意文字与韩文音节不受 NFKC 影响")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(TranslationService.normalizeForTranslation("  文本  "), "文本")
    }

    func testNormalizeHangulCompatibleJamo() {
        // 兼容 Jamo 归一为标准形后仍是有效韩文（检测不破坏）。
        let normalized = TranslationService.normalizeForTranslation("안녕")
        XCTAssertEqual(SubtitleLanguage.detect(normalized), .korean)
    }
}
