import XCTest
@testable import WhisperASR

/// 流式引擎喂音水位线回归（调度层统一去重）：
/// tail 重转录的重叠区间裁剪、静音跳过、强制封口上下文重发、
/// 无区间保守回退、引擎切换/停录重置。
final class StreamingWaterlineTests: XCTestCase {

    func testFirstFeedFeedsAll() {
        var w = StreamingFeedWaterline()
        // 首次：水位线空 → 从区间头喂全部。
        let start = w.unfedStart(in: 0..<8000)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(w.fedUntil, 8000)
    }

    func testOverlappingTailOnlyFeedsNewPart() {
        var w = StreamingFeedWaterline()
        _ = w.unfedStart(in: 0..<8000)
        // 下一轮 tail 重发 [2000..<12000)：只应喂 8000 起的新增（下标 6000）。
        let start = w.unfedStart(in: 2000..<12000)
        XCTAssertEqual(start, 6000)
        XCTAssertEqual(w.fedUntil, 12000)
    }

    func testFullyOverlappingFeedReturnsNil() {
        var w = StreamingFeedWaterline()
        _ = w.unfedStart(in: 0..<12000)
        // 区间完全已喂（静音跳过后下轮 tail 未推进）：不喂。
        XCTAssertNil(w.unfedStart(in: 0..<12000))
        XCTAssertEqual(w.fedUntil, 12000, "重复调用不推进水位线")
    }

    func testSilenceSkipThenResumeFeedsFromBoundary() {
        var w = StreamingFeedWaterline()
        _ = w.unfedStart(in: 0..<8000)
        // 静音跳过：下轮区间推进到 [16000..<24000)（前段静音未经过本路径）。
        // 水位线在 8000 → 新增从 16000 起（区间内下标 0），静音段 [8000,16000)
        // 不喂（sealSilence 路径的采样本来就不该喂）。
        let start = w.unfedStart(in: 16000..<24000)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(w.fedUntil, 24000)
    }

    func testForcedSealContextNotRefed() {
        var w = StreamingFeedWaterline()
        _ = w.unfedStart(in: 0..<16000)
        // 强制封口后上层重发 1s 上下文 [15200..<16000)：全部已喂 → nil。
        XCTAssertNil(w.unfedStart(in: 15200..<16000))
    }

    func testUntrackedFeedResetsWaterline() {
        var w = StreamingFeedWaterline()
        _ = w.unfedStart(in: 0..<8000)
        // 无区间路径：保守全量喂 + 清空水位线（下次带区间调用重喂整段，
        // 宁可一次性重复不能永久漏音）。
        w.markUntrackedFeed()
        XCTAssertNil(w.fedUntil)
        XCTAssertEqual(w.unfedStart(in: 0..<8000), 0)
    }

    func testResetClearsState() {
        var w = StreamingFeedWaterline()
        _ = w.unfedStart(in: 0..<8000)
        w.reset()
        XCTAssertNil(w.fedUntil)
        XCTAssertEqual(w.unfedStart(in: 0..<8000), 0, "重置后重新从区间头喂")
    }

    func testWaterlineMonotonicOnShrinkingRanges() {
        var w = StreamingFeedWaterline()
        _ = w.unfedStart(in: 0..<10000)
        // 异常路径：区间右端回缩（< 已喂位置）→ nil 且水位线不回退。
        XCTAssertNil(w.unfedStart(in: 0..<6000))
        XCTAssertEqual(w.fedUntil, 10000)
    }
}
