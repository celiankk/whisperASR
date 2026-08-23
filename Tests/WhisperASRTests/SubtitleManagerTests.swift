import XCTest
@testable import WhisperASR

/// SubtitleManager 纯逻辑回归：pendingTail 跨 pass 累积（增量引擎不丢前半句）、
/// 封口提交/留存、静音封口不丢文本、trimOverlap 去重。
/// 对应 HANDOFF 第 14 节（断句优化）与坑 17。
final class SubtitleManagerTests: XCTestCase {

    private func seg(_ start: Double, _ text: String) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: nil, text: text)
    }

    // MARK: 增量累积（Apple 引擎语义）

    func testIncrementalAccumulatesAcrossPasses() {
        let manager = SubtitleManager()
        // 三轮增量：当前句必须完整累积为单一 pending 段。
        let r1 = manager.appendTail(
            tailSegments: [seg(0, "今天天气")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        let r2 = manager.appendTail(
            tailSegments: [seg(1, "很好我们")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        let r3 = manager.appendTail(
            tailSegments: [seg(2, "出去走走")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)

        for combined in [r1, r2, r3] {
            XCTAssertEqual(combined.count, 1, "增量累积期间 combined = sealed(空) + 单一当前句段")
        }
        XCTAssertEqual(r3.first?.text, "今天天气很好我们出去走走")
        XCTAssertEqual(manager.pendingTailSegments.count, 1)
        XCTAssertEqual(manager.pendingTailSegments.first?.text, "今天天气很好我们出去走走")
    }

    func testIncrementalEnglishJoinedWithSpace() {
        let manager = SubtitleManager()
        manager.appendTail(tailSegments: [seg(0, "hello")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        let combined = manager.appendTail(
            tailSegments: [seg(1, "world")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        XCTAssertEqual(combined.first?.text, "hello world", "西文拼接补空格")
    }

    func testIncrementalChineseJoinedWithoutSpace() {
        let manager = SubtitleManager()
        manager.appendTail(tailSegments: [seg(0, "你好")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        let combined = manager.appendTail(
            tailSegments: [seg(1, "世界")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        XCTAssertEqual(combined.first?.text, "你好世界", "中文直接相连")
    }

    func testIncrementalEmptyPassKeepsPending() {
        let manager = SubtitleManager()
        manager.appendTail(tailSegments: [seg(0, "前半句")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        // 空结果 pass（引擎没出字）：pending 不丢、不重复。
        let combined = manager.appendTail(tailSegments: [], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.text, "前半句")
    }

    // MARK: 全量替换（whisper 语义）

    func testFullTailReplacesPending() {
        let manager = SubtitleManager()
        manager.appendTail(tailSegments: [seg(0, "旧尾")], tailStartTime: 0, useOverlap: false, mergePolicy: .replaceTail)
        let combined = manager.appendTail(
            tailSegments: [seg(0, "旧尾新词")], tailStartTime: 0, useOverlap: false, mergePolicy: .replaceTail)
        XCTAssertEqual(combined.first?.text, "旧尾新词", "全量引擎每轮整段替换")
        XCTAssertEqual(manager.pendingTailSegments.count, 1)
    }

    // MARK: 封口

    func testSealCommitsPendingAndKeepsRemainder() {
        let manager = SubtitleManager()
        // 全量引擎语义：两段独立段（增量模式下多段会被合并为单一当前句，
        // 那是设计行为——见 testIncrementalAccumulatesAcrossPasses）。
        let combined = manager.appendTail(
            tailSegments: [seg(0, "第一句"), seg(5, "第二句")], tailStartTime: 0, useOverlap: false, mergePolicy: .replaceTail)
        XCTAssertEqual(combined.count, 2)
        // 第一段在封口线（2s）之前 → 提交；第二段在其后 → 留作下一句 pending。
        manager.seal(upToSampleCount: 2 * 16000, clean: true, combined: combined)
        XCTAssertEqual(manager.sealedSegments.map(\.text), ["第一句"])
        XCTAssertEqual(manager.pendingTailSegments.map(\.text), ["第二句"], "封口后的段留作下一句起点，不丢失")
        XCTAssertEqual(manager.sealedSampleCount, 2 * 16000)
        XCTAssertTrue(manager.sealedClean)
    }

    func testIncrementalSealCommitsWholeSentence() {
        let manager = SubtitleManager()
        // 增量模式：三轮碎片合并为一句；VAD 封口时整句提交。
        _ = manager.appendTail(tailSegments: [seg(0, "你")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        _ = manager.appendTail(tailSegments: [seg(1, "陪我唱")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        let combined = manager.appendTail(tailSegments: [seg(2, "歌")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.text, "你陪我唱歌")
        manager.sealSilence(upToSampleCount: 3 * 16000)
        XCTAssertEqual(manager.sealedSegments.map(\.text), ["你陪我唱歌"], "静音封口固化完整当前句")
    }

    func testSealSilenceCommitsPendingText() {
        let manager = SubtitleManager()
        let combined = manager.appendTail(
            tailSegments: [seg(0, "最后一句")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        XCTAssertEqual(combined.count, 1)
        // 静音路径不经过常规 seal：pending 文本必须一并固化（不丢句首）。
        manager.sealSilence(upToSampleCount: 9 * 16000)
        XCTAssertEqual(manager.sealedSegments.map(\.text), ["最后一句"])
        XCTAssertTrue(manager.pendingTailSegments.isEmpty)
    }

    func testClearResetsAllState() {
        let manager = SubtitleManager()
        _ = manager.appendTail(tailSegments: [seg(0, "文本")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        manager.seal(upToSampleCount: 16000, clean: true, combined: manager.sealedSegments + manager.pendingTailSegments)
        manager.clear()
        XCTAssertTrue(manager.sealedSegments.isEmpty)
        XCTAssertTrue(manager.pendingTailSegments.isEmpty)
        XCTAssertEqual(manager.sealedSampleCount, 0)
    }

    // MARK: StreamingState（显式实时状态快照）

    func testStreamingStateTransitions() {
        let manager = SubtitleManager()
        XCTAssertEqual(manager.streamingState, .idle)

        // partial 增量 → .partial；空 pass 不回退状态。
        manager.appendTail(tailSegments: [seg(0, "今天")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        XCTAssertEqual(manager.streamingState, .partial)
        manager.appendTail(tailSegments: [], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        XCTAssertEqual(manager.streamingState, .partial)

        // 静音封口（整句提交、tail 清空）→ .recognizing。
        manager.sealSilence(upToSampleCount: 2 * 16000)
        XCTAssertEqual(manager.streamingState, .recognizing)

        // 全量替换引擎新一轮 → .partial。
        manager.appendTail(tailSegments: [seg(3, "下一句")], tailStartTime: 0, useOverlap: false, mergePolicy: .replaceTail)
        XCTAssertEqual(manager.streamingState, .partial)

        // 常规封口：封口线(3.5s)之前提交、之后的段留存 → .partial。
        manager.appendTail(tailSegments: [seg(4, "留存段")], tailStartTime: 0, useOverlap: false, mergePolicy: .replaceTail)
        manager.seal(upToSampleCount: Int(3.5 * 16000), clean: true,
                     combined: manager.sealedSegments + manager.pendingTailSegments)
        XCTAssertEqual(manager.pendingTailSegments.map(\.text), ["留存段"])
        XCTAssertEqual(manager.streamingState, .partial)

        // stop → .completed；clear → .idle。
        manager.stop()
        XCTAssertEqual(manager.streamingState, .completed)
        manager.clear()
        XCTAssertEqual(manager.streamingState, .idle)
    }

    func testSealToRecognizingWhenTailEmpty() {
        let manager = SubtitleManager()
        manager.appendTail(tailSegments: [seg(0, "完整句")], tailStartTime: 0, useOverlap: false, mergePolicy: .appendIncrement)
        // 封口线在所有段之后：pending 清空 → .recognizing（停顿中）。
        manager.seal(upToSampleCount: 5 * 16000, clean: true,
                     combined: manager.sealedSegments + manager.pendingTailSegments)
        XCTAssertTrue(manager.pendingTailSegments.isEmpty)
        XCTAssertEqual(manager.streamingState, .recognizing)
    }

    // MARK: trimOverlap（whisper 强制封口后的 1s 上下文去重）

    func testTrimOverlapTrimsDuplicatedPrefix() {
        // trimOverlap 裁掉与 previous 重叠的前缀「结尾」；剩余部分
        // 原样保留（含前导空白——调用方 appendTail 有非空校验与 trim）。
        let trimmed = SubtitleManager.trimOverlap(previous: "…前文结尾", current: "结尾 新内容")
        XCTAssertTrue(trimmed.hasSuffix("新内容"), "重叠前缀应被裁掉，实际：\(trimmed)")
        XCTAssertFalse(trimmed.hasPrefix("结尾"))
    }

    func testTrimOverlapNoMatchReturnsUnchanged() {
        let trimmed = SubtitleManager.trimOverlap(previous: "完全不同", current: "全新句子")
        XCTAssertEqual(trimmed, "全新句子")
    }

    func testTrimOverlapIgnoresBoundaryPunctuation() {
        // 边界标点剥离后仍可匹配：返回「， 后续」剥离前缀后的剩余
        //（trimOverlap 语义 = 去掉与 previous 重叠的开头部分）。
        let trimmed = SubtitleManager.trimOverlap(previous: "句子，", current: "句子， 后续")
        XCTAssertEqual(
            trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "， ")),
            "后续")
    }
}
