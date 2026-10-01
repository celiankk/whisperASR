import XCTest
@testable import WhisperASR

// MARK: - 实时译文落库对齐测试
//
// 回归保护：`AppState.liveTranslatedSegments` 全项目无写入点（恒为空），
// 录制落库与崩溃恢复改从 `SubtitleHistoryManager` 按原文回填译文。
// 这里锁定对齐语义：等长、未命中为空串、无译文时返回空数组。

final class SubtitleHistoryAlignmentTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 单例：每个用例从干净状态开始（startLive 也会 clear，测试里显式清）。
        SubtitleHistoryManager.shared.clear()
    }

    override func tearDown() {
        SubtitleHistoryManager.shared.clear()
        super.tearDown()
    }

    private func segment(_ text: String, start: Double = 0) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: start + 1, text: text)
    }

    func testAlignedTranslationsMatchesByOriginalText() {
        let history = SubtitleHistoryManager.shared
        history.record(original: "你好世界", translation: "Hello world", language: "zh")
        history.record(original: "第二句话", translation: "Second sentence", language: "zh")

        let segments = [segment("你好世界"), segment("第二句话")]
        XCTAssertEqual(
            history.alignedTranslations(for: segments),
            ["Hello world", "Second sentence"])
    }

    func testAlignedTranslationsTrimsSegmentTextBeforeMatching() {
        let history = SubtitleHistoryManager.shared
        history.record(original: "带空格", translation: "spaced", language: "zh")

        // 分段文本两侧带空白仍应命中（对齐前统一 trim）。
        let segments = [segment("  带空格\n")]
        XCTAssertEqual(history.alignedTranslations(for: segments), ["spaced"])
    }

    func testAlignedTranslationsFillsEmptyStringForUnmatchedSegment() {
        let history = SubtitleHistoryManager.shared
        history.record(original: "命中", translation: "hit", language: "zh")

        let segments = [segment("命中"), segment("没有译文")]
        // 长度必须与 segments 等长，未命中位置为空串（不能塌缩数组）。
        XCTAssertEqual(history.alignedTranslations(for: segments), ["hit", ""])
    }

    func testAlignedTranslationsReturnsEmptyArrayWhenNoTranslations() {
        let history = SubtitleHistoryManager.shared
        history.record(original: "只有原文", translation: nil, language: "zh")

        let segments = [segment("只有原文")]
        // 无任何可用译文 → 空数组（调用方据此把 translationLanguage 置 nil）。
        XCTAssertEqual(history.alignedTranslations(for: segments), [])
    }

    func testAlignedTranslationsIgnoresBlankTranslations() {
        let history = SubtitleHistoryManager.shared
        history.record(original: "空白译文", translation: "   ", language: "zh")

        XCTAssertEqual(history.alignedTranslations(for: [segment("空白译文")]), [])
    }

    func testAlignedTranslationsPreservesSegmentOrder() {
        let history = SubtitleHistoryManager.shared
        history.record(original: "A", translation: "甲", language: "en")
        history.record(original: "B", translation: "乙", language: "en")
        history.record(original: "C", translation: "丙", language: "en")

        let segments = [segment("C"), segment("A"), segment("B")]
        XCTAssertEqual(history.alignedTranslations(for: segments), ["丙", "甲", "乙"])
    }
}
