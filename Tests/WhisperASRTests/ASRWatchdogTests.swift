import XCTest
@testable import WhisperASR

/// 内存回收策略回归（ASR 看门狗段 1）：
/// 超阈值/空闲/冷却三条件联合判定。
final class ASRWatchdogTests: XCTestCase {

    private let policy = MemoryReclaimPolicy(ceilingBytes: 1_000_000_000, cooldown: 60)
    private let now = Date()

    func testOverCeilingAndIdleReclaims() {
        XCTAssertTrue(policy.shouldReclaim(
            footprintBytes: 1_500_000_000, asrIdle: true, transcriptionIdle: true,
            lastReclaim: nil, now: now))
    }

    func testUnderCeilingNoReclaim() {
        XCTAssertFalse(policy.shouldReclaim(
            footprintBytes: 800_000_000, asrIdle: true, transcriptionIdle: true,
            lastReclaim: nil, now: now))
    }

    func testActiveASRNoReclaim() {
        XCTAssertFalse(policy.shouldReclaim(
            footprintBytes: 1_500_000_000, asrIdle: false, transcriptionIdle: true,
            lastReclaim: nil, now: now))
    }

    func testActiveTranscriptionNoReclaim() {
        XCTAssertFalse(policy.shouldReclaim(
            footprintBytes: 1_500_000_000, asrIdle: true, transcriptionIdle: false,
            lastReclaim: nil, now: now))
    }

    func testCooldownBlocksRepeat() {
        let justReclaimed = now.addingTimeInterval(-10)
        XCTAssertFalse(policy.shouldReclaim(
            footprintBytes: 1_500_000_000, asrIdle: true, transcriptionIdle: true,
            lastReclaim: justReclaimed, now: now))
    }

    func testCooldownExpiredAllowsAgain() {
        let longAgo = now.addingTimeInterval(-120)
        XCTAssertTrue(policy.shouldReclaim(
            footprintBytes: 1_500_000_000, asrIdle: true, transcriptionIdle: true,
            lastReclaim: longAgo, now: now))
    }

    func testZeroFootprintNeverReclaims() {
        // 采样失败（0）静默不触发。
        XCTAssertFalse(policy.shouldReclaim(
            footprintBytes: 0, asrIdle: true, transcriptionIdle: true,
            lastReclaim: nil, now: now))
    }

    func testBoundaryExactlyAtCeilingReclaims() {
        XCTAssertTrue(policy.shouldReclaim(
            footprintBytes: 1_000_000_000, asrIdle: true, transcriptionIdle: true,
            lastReclaim: nil, now: now), "等于上限即触发（≥ 语义）")
    }

    func testProcessMemorySamplingReturnsSaneValue() {
        // 采样接口冒烟：本进程 footprint 应在 (0, 64GB) 区间。
        let footprint = ProcessMemory.footprintBytes
        XCTAssertGreaterThan(footprint, 0)
        XCTAssertLessThan(footprint, 64_000_000_000)
    }
}
