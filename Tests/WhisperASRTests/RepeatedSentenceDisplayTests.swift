import XCTest
@testable import WhisperASR

// MARK: - 新句判定回归（P1）
//
// 背景：同一会话里说第二遍同一句话（"好的。" → 稍后又"好的。"）曾被
// 永久静音——旧判据只比「末段文本是否变化」，而文本记录只在换会话时
// 清空，第二次文本相同 → 既不显示也不触发翻译，屏幕保持空白。
//
// 本测试锁定 SubtitleSentenceTrigger 的语义（View 层完成判据的事实来源）。

final class SubtitleSentenceTriggerTests: XCTestCase {

    func testFirstSentenceTriggers() {
        var trigger = SubtitleSentenceTrigger()
        XCTAssertTrue(trigger.shouldTrigger(text: "好的。", start: 0),
                      "首句必须触发")
    }

    func testSameSnapshotDoesNotTriggerTwice() {
        var trigger = SubtitleSentenceTrigger()
        XCTAssertTrue(trigger.shouldTrigger(text: "好的。", start: 0))
        // 静音轮询重复推送同一快照（文本与起点都不变）：不得重复触发。
        XCTAssertFalse(trigger.shouldTrigger(text: "好的。", start: 0),
                       "相同快照重复推送不应再次触发")
        XCTAssertFalse(trigger.shouldTrigger(text: "好的。", start: 0))
    }

    func testRepeatedSentenceAtNewStartStillTriggers() {
        var trigger = SubtitleSentenceTrigger()
        XCTAssertTrue(trigger.shouldTrigger(text: "好的。", start: 0))
        // 用户稍后又说了一遍同样的话：文本相同，但起点前移（新封口段）。
        XCTAssertTrue(trigger.shouldTrigger(text: "好的。", start: 12.5),
                      "重复说同一句必须再次触发（曾被文本相同判据永久静音）")
    }

    func testTextChangeAtSameStartTriggers() {
        var trigger = SubtitleSentenceTrigger()
        XCTAssertTrue(trigger.shouldTrigger(text: "ta pop", start: 3.0))
        // Apple 的 final 修正：起点未变但文本被改写。
        XCTAssertTrue(trigger.shouldTrigger(text: "pop", start: 3.0),
                      "final 文本修正应触发")
    }

    func testResetAllowsSameSentenceInNewSession() {
        var trigger = SubtitleSentenceTrigger()
        XCTAssertTrue(trigger.shouldTrigger(text: "好的。", start: 0))
        trigger.reset()
        XCTAssertTrue(trigger.shouldTrigger(text: "好的。", start: 0),
                      "新会话第一句与上一会话末句相同必须能显示")
    }
}
