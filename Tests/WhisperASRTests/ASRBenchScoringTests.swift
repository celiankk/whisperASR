import XCTest
@testable import WhisperASR

// MARK: - 评测工作台的评分指标（ASRBench）
//
// 工作台的所有结论都建立在评分器正确之上——评分器错了，调优方向就会错。
// 这里锁定三类核心行为：
//   1) 标点/全半角/大小写不该算错（否则指标反映"写法像不像"而非"内容对不对"）；
//   2) 中文数词与阿拉伯数字是等义写法（"百分之十二点五" == "12.5%"）；
//   3) 真正的识别错误必须被算出来（不能因为归一化过宽而漏报）。
final class ASRBenchScoringTests: XCTestCase {

    private func cer(_ ref: String, _ hyp: String) -> Double {
        ASRBench.errorRate(reference: ref, hypothesis: hyp)
    }

    // MARK: 归一化：不该算错的差异

    func testPunctuationAndCaseDoNotCount() {
        XCTAssertEqual(cer("hello world", "Hello, world."), 0,
                       "标点与大小写差异不该算识别错误")
        XCTAssertEqual(cer("今天天气很好，我们出去走走吧。", "今天天气很好我们出去走走吧"), 0,
                       "标点差异不该算识别错误")
    }

    func testFullWidthEqualsHalfWidth() {
        XCTAssertEqual(cer("ABC 123", "ＡＢＣ　１２３"), 0)
    }

    func testChineseNumeralsEqualArabic() {
        XCTAssertEqual(cer("第三季度营收增长百分之十二点五。",
                           "第三季度营收增长12.5%"), 0,
                       "「百分之十二点五」与「12.5%」是等义写法")
        XCTAssertEqual(cer("三十五个人", "35个人"), 0)
        XCTAssertEqual(cer("一百二十元", "120元"), 0)
        XCTAssertEqual(cer("十五号", "15号"), 0)
    }

    /// 「点」既可能是小数点（十二点五），也可能是钟点（三点钟）。
    ///
    /// 早期实现把「点」一律并入数词缓冲，导致 `三点` 归一成 `3`、`3点`
    /// 归一成 `30` —— 两种正确写法被判成 100% 错误（把正确识别记成全错）。
    func testClockTimeDianIsNotDecimalPoint() {
        XCTAssertEqual(cer("我们下午三点开始", "我们下午3点开始"), 0,
                       "「三点」与「3点」是等义写法")
        XCTAssertEqual(cer("请把空调温度调到二十六度。", "请把空调温度调到26度。"), 0,
                       "「二十六度」与「26度」是等义写法")
        // 真正的小数点仍须保留，否则「十二点五」与「12.5」不等价。
        XCTAssertEqual(cer("增长百分之十二点五", "增长12.5%"), 0)
    }

    // MARK: 真正的错误必须被算出来

    func testRealSubstitutionIsCounted() {
        // AWS 被听成 Auth：2 处差异 / 参考长度
        let rate = cer("我们在 AWS 上发布", "我们在 Auth 上发布")
        XCTAssertGreaterThan(rate, 0, "专名识别错误必须被计入")
    }

    func testMissingContentIsCounted() {
        XCTAssertGreaterThan(cer("今天天气很好", "今天天气"), 0, "丢字必须计入")
        XCTAssertGreaterThan(cer("hello world", "hello"), 0)
    }

    func testExtraContentIsCounted() {
        XCTAssertGreaterThan(cer("今天天气", "今天天气很好"), 0, "多字必须计入")
    }

    func testCompletelyWrongIsFullError() {
        XCTAssertEqual(cer("今天天气很好", "完全无关内容啊"), 1.0, accuracy: 0.001,
                       "毫不相关应逼近 100% 错误率")
    }

    func testEmptyHypothesisIsFullError() {
        XCTAssertEqual(cer("今天天气很好", ""), 1.0, accuracy: 0.001)
    }

    // MARK: 编辑距离本身

    func testEditDistanceBasics() {
        XCTAssertEqual(ASRBench.editDistance([], []), 0)
        XCTAssertEqual(ASRBench.editDistance(["a"], []), 1)
        XCTAssertEqual(ASRBench.editDistance([], ["a", "b"]), 2)
        XCTAssertEqual(ASRBench.editDistance(["a", "b"], ["a", "b"]), 0)
        XCTAssertEqual(ASRBench.editDistance(["a", "b"], ["a", "c"]), 1)      // 替换
        XCTAssertEqual(ASRBench.editDistance(["a", "b"], ["a"]), 1)           // 删除
        XCTAssertEqual(ASRBench.editDistance(["a"], ["a", "b"]), 1)           // 插入
    }

    func testSegmentationByScript() {
        XCTAssertEqual(ASRBench.segment(normalized: "今天天气"), ["今", "天", "天", "气"],
                       "含 CJK 按字切分")
        XCTAssertEqual(ASRBench.segment(normalized: "hello world"), ["hello", "world"],
                       "纯拉丁按词切分")
    }

    // MARK: 译文一致度（宽松指标，只用于发现跑偏）

    func testTranslationF1PerfectAndEmpty() {
        XCTAssertEqual(ASRBench.charF1(reference: "你好世界", hypothesis: "你好世界"), 1.0,
                       accuracy: 0.001)
        XCTAssertEqual(ASRBench.charF1(reference: "你好世界", hypothesis: ""), 0,
                       "空译文一致度为 0（工作台据此标记异常组合）")
    }

    func testTranslationF1DifferentWordingStillScoresHigh() {
        // 翻译没有唯一答案，措辞不同但内容相关应得高分（不该被判为失败）。
        // 阈值取 0.5：足以把"同义改写"与"完全跑偏"（≈0）分开，
        // 又不假装字级 F1 能精确度量翻译质量——它只用于发现硬故障。
        let f1 = ASRBench.charF1(reference: "今天天气很好",
                                 hypothesis: "今天天气不错")
        XCTAssertGreaterThanOrEqual(f1, 0.5, "同义改写不该被判为跑偏：\(f1)")
        // 对照组：毫不相关应当很低，且必须显著低于同义改写。
        let unrelated = ASRBench.charF1(reference: "今天天气很好",
                                        hypothesis: "退货流程说明")
        XCTAssertLessThan(unrelated, 0.3, "无关译文应得低分：\(unrelated)")
        XCTAssertGreaterThan(f1, unrelated, "同义改写必须显著高于无关内容")
    }
}
