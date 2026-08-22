import XCTest
@testable import WhisperASR

/// 翻译响应解析回归：JSON 数组批量（防串句）、编号回退、思考分离、单句净化。
final class TranslationParsingTests: XCTestCase {

    // MARK: JSON 数组批量

    func testJSONArrayParsing() {
        let content = #"["第一句译文", "第二句译文", "第三句译文"]"#
        let result = TranslationService.parseTranslationArray(content, count: 3)
        XCTAssertEqual(result, ["第一句译文", "第二句译文", "第三句译文"])
    }

    func testJSONArrayWithMarkdownFence() {
        let content = """
        ```json
        ["a", "b"]
        ```
        """
        XCTAssertEqual(TranslationService.parseTranslationArray(content, count: 2), ["a", "b"])
    }

    func testJSONArrayWithLeadingText() {
        // 模型偶尔在数组前后加说明文字：取首个 [ 到最后一个 ]。
        let content = "以下是翻译结果：[\"x\", \"y\"] 希望有帮助"
        XCTAssertEqual(TranslationService.parseTranslationArray(content, count: 2), ["x", "y"])
    }

    func testJSONArrayCountMismatchReturnsNil() {
        // 句数不符 → nil（调用方回退编号解析，防错位串句）。
        XCTAssertNil(TranslationService.parseTranslationArray(#"["a", "b"]"#, count: 3))
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(TranslationService.parseTranslationArray("not json at all", count: 1))
    }

    // MARK: 编号行回退

    func testNumberedParsing() {
        let content = "1. 第一句\n2. 第二句"
        XCTAssertEqual(TranslationService.parseNumberedLines(content, count: 2),
                       ["第一句", "第二句"])
    }

    func testNumberedParsingPadsMissing() {
        XCTAssertEqual(TranslationService.parseNumberedLines("1. 只有第一句", count: 2),
                       ["只有第一句", ""])
    }

    // MARK: 思考分离

    func testExtractContentPrefersContent() {
        let message: [String: Any] = ["content": "译文", "reasoning_content": "思考过程"]
        XCTAssertEqual(TranslationService.extractContent(from: message), "译文")
    }

    func testExtractContentFallsBackToReasoningTail() {
        // 思考模型把正文误放 reasoning_content：取末段（非空判定）。
        let message: [String: Any] = [
            "content": "",
            "reasoning_content": "思考第一行\n这是译文正文",
        ]
        XCTAssertEqual(TranslationService.extractContent(from: message), "这是译文正文")
    }

    func testExtractContentNilWhenBothEmpty() {
        let message: [String: Any] = ["content": "", "reasoning_content": ""]
        XCTAssertNil(TranslationService.extractContent(from: message))
    }

    // MARK: 单句净化

    func testStripSingleLineNoise() {
        XCTAssertEqual(TranslationService.stripSingleLineNoise("1. 译文"), "译文")
        XCTAssertEqual(TranslationService.stripSingleLineNoise("\"带引号的译文\""), "带引号的译文")
        XCTAssertEqual(TranslationService.stripSingleLineNoise("  普通译文  "), "普通译文")
    }
}


// MARK: 复读机检测（小模型循环输出防护）
final class RepetitionDetectionTests: XCTestCase {

    func testShortTextNeverRepetitive() {
        XCTAssertFalse(TranslationService.hasRepetition("短文本不会误判"))
        XCTAssertFalse(TranslationService.hasRepetition(""))
    }

    func testLoopOutputDetected() {
        // 典型循环：同一短语反复（≥3 次相同 8 字片段）。
        let loop = String(repeating: "今天天气真好我们去", count: 8)
        XCTAssertTrue(TranslationService.hasRepetition(loop))
    }

    func testNormalLongTextNotFlagged() {
        // 正常多样长文本（无周期重复）。
        let text = """
        会议讨论了三个议题：首先是项目进度，团队完成了百分之七十的开发工作；         其次是测试安排，下周进入集成测试阶段；最后是发布计划，预计月底交付首个版本。         各团队负责人确认了风险清单与应对方案，下周例会同步最新进展。
        """
        XCTAssertFalse(TranslationService.hasRepetition(text))
    }
}

// MARK: 输入补零桶化（可配置）
final class InputBucketingConfigTests: XCTestCase {

    func testZeroDisables() {
        UserDefaults.standard.set(0.0, forKey: "asrPadSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "asrPadSeconds") }
        let samples: [Float] = [0.1, 0.2, 0.3]
        XCTAssertTrue(InputBucketing.padded(samples).elementsEqual(samples),
                      "0 = 禁用，原样返回")
    }

    func testCustomQuantum() {
        UserDefaults.standard.set(1.0, forKey: "asrPadSeconds")   // 1s = 16000
        defer { UserDefaults.standard.removeObject(forKey: "asrPadSeconds") }
        let padded = InputBucketing.padded([Float](repeating: 0.1, count: 9_000))
        XCTAssertEqual(padded.count, 16_000, "1s 桶补到 16000")
    }
}
