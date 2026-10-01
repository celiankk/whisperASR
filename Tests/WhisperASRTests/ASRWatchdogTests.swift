import XCTest
@testable import WhisperASR

// MARK: - 超时兜底回归
//
// 背景：旧实现用 throwing task group，而作用域退出会**等待**全部子任务。
// whisper_full / Qwen / Nemotron 的推理都是 actor 内同步调用、不检查取消，
// 于是超时后仍要等推理跑完才返回——GPU 死锁时 live loop 永久冻结，
// 看门狗「连续 2 次超时卸载模型重建」的恢复路径不可达。
// 本测试证明：对**完全不协作取消**的工作，超时也能按时返回。
final class ASRTimeoutTests: XCTestCase {

    func testTimeoutFiresDespiteNonCooperativeWork() async {
        let start = Date()
        do {
            _ = try await ASRManager.withTimeout(seconds: 0.2) {
                // 纯同步忙等、绝不检查 Task.isCancelled（模拟 whisper_full）。
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline { usleep(10_000) }
                return "done"
            }
            XCTFail("应当超时抛出")
        } catch is ASRManager.TimeoutError {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2.0,
                              "超时必须在规定时间内返回（实际 \(elapsed)s）——旧 task group 实现会等到工作跑完")
        } catch {
            XCTFail("应抛 TimeoutError，实际 \(error)")
        }
    }

    func testResultPassesThroughWhenFastEnough() async throws {
        let result = try await ASRManager.withTimeout(seconds: 5) { "ok" }
        XCTAssertEqual(result, "ok")
    }

    func testPropagatesOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await ASRManager.withTimeout(seconds: 5) { throw Boom() }
            XCTFail("应向上抛出原始错误")
        } catch is Boom {
            // 预期
        } catch {
            XCTFail("错误类型被吞/替换：\(error)")
        }
    }
}

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
