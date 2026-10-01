import XCTest
@testable import WhisperASR

// MARK: - KVCacheSession 编排逻辑单测（纯逻辑层，无 MLX 依赖）
//
// 用 RecordingFakeBackend 记录后端调用序列，验证：
// - 增量追加的 position 自增连续性与 mask 行语义（RoPE 防错位核心）；
// - 容量规划三分支（直通 / 滑窗重建 / 全量重置）的边界与簿记；
// - 失效信号（音频不连续等）的懒生效与缓存清空。
final class KVCacheSessionTests: XCTestCase {

    /// 记录型假后端：验证 session → backend 的调用编排。
    private final class RecordingFakeBackend: KVCacheBackend {
        let maxContextTokens: Int
        struct ComputeCall: Equatable {
            let tokens: [Int]
            let positions: Range<Int>
            let attendableCounts: [Int]
        }
        private(set) var computeCalls: [ComputeCall] = []
        private(set) var writeOffsets: [Int] = []
        private(set) var reprefillWindows: [[Int]] = []
        private(set) var resetCount = 0

        init(maxContextTokens: Int) {
            self.maxContextTokens = maxContextTokens
        }

        func computeNewKV(tokens: [Int],
                          positions: Range<Int>,
                          attendableCounts: [Int]) async throws -> KVNewKV {
            computeCalls.append(ComputeCall(tokens: tokens,
                                            positions: positions,
                                            attendableCounts: attendableCounts))
            let tensor = KVTensor(dims: [1, tokens.count, 4])
            return KVNewKV(tokenCount: tokens.count, k: [tensor], v: [tensor])
        }

        func write(offset: Int, kv: KVNewKV) throws {
            writeOffsets.append(offset)
        }

        func reprefillWindow(tokenIDs: [Int]) async throws {
            reprefillWindows.append(tokenIDs)
        }

        func resetAll() {
            resetCount += 1
        }
    }

    // MARK: mask / position 语义（RoPE 防错位核心）

    func testPositionsAndAttendableCountsSemantics() {
        // 缓存 2000、新增 200：位置 2000..<2200 连续自增。
        XCTAssertEqual(KVCacheSession.positions(afterCachedLength: 2000, newCount: 200),
                       2000..<2200)
        // 第 j 个新 token 可 attend 前 C+j+1 个（前缀全 1 + 新区因果）。
        let counts = KVCacheSession.attendableCounts(cachedLength: 2000, newCount: 3)
        XCTAssertEqual(counts, [2001, 2002, 2003])
        // 解码步：全历史 + 自身。
        XCTAssertEqual(KVCacheSession.decodeAttendableCount(cachedLength: 2199), 2200)
    }

    // MARK: 正常增量追加

    func testIncrementalAppendsKeepContinuousPositions() async throws {
        let backend = RecordingFakeBackend(maxContextTokens: 100)
        let session = KVCacheSession(maxContextTokens: 100, keepTargetTokens: 50, backend: backend)

        let first = try await session.prefillIncremental(Array(1...10))
        XCTAssertFalse(first.rebuiltFirst)
        XCTAssertEqual(first.cacheOffset, 0)
        XCTAssertEqual(first.positions, 0..<10)
        XCTAssertEqual(first.attendableCounts, Array(1...10))
        XCTAssertEqual(session.cachedPrefixLength, 10)
        XCTAssertEqual(session.generation, 0)

        let second = try await session.prefillIncremental(Array(11...15))
        XCTAssertEqual(second.cacheOffset, 10)
        XCTAssertEqual(second.positions, 10..<15)
        XCTAssertEqual(second.attendableCounts, Array(11...15))
        XCTAssertEqual(session.cachedPrefixLength, 15)
        XCTAssertEqual(session.generation, 0, "no rebuild should bump generation")

        // 后端只收到「新增 token」的前向请求（P0 复用目标：前缀零重算）。
        XCTAssertEqual(backend.computeCalls.map(\.tokens), [Array(1...10), Array(11...15)])
        XCTAssertEqual(backend.writeOffsets, [0, 10])
    }

    /// 解码步容量守卫：连续 decode 推满缓存后应抛语义化容量错误
    /// （解码循环据此触发淘汰/重 prefill），而非物理越界。
    func testDecodeStepThrowsOnCapacityExceeded() async throws {
        let backend = RecordingFakeBackend(maxContextTokens: 100)
        let session = KVCacheSession(maxContextTokens: 100, keepTargetTokens: 50, backend: backend)
        _ = try await session.prefillIncremental(Array(1...95))
        // 95 + 5 步解码 = 100（到顶）；第 6 步必须抛容量错误。
        for _ in 0..<5 {
            _ = try await session.decodeStep(999)
        }
        XCTAssertEqual(session.cachedPrefixLength, 100)
        do {
            _ = try await session.decodeStep(999)
            XCTFail("decode beyond maxContextTokens must throw")
        } catch let e as KVCacheError {
            XCTAssertEqual(e, .capacityExceeded(needed: 101, capacity: 100))
        }
        XCTAssertEqual(session.cachedPrefixLength, 100, "failed step must not advance cursor")
    }

    func testDecodeStepAttendsWholeCache() async throws {
        let backend = RecordingFakeBackend(maxContextTokens: 100)
        let session = KVCacheSession(maxContextTokens: 100, keepTargetTokens: 50, backend: backend)
        _ = try await session.prefillIncremental(Array(1...10))
        let receipt = try await session.decodeStep(99)
        XCTAssertEqual(receipt.cacheOffset, 10)
        XCTAssertEqual(receipt.attendableCount, 11)
        XCTAssertEqual(session.cachedPrefixLength, 11)
    }

    // MARK: 滑动窗口（上下文超限，单块新增 ≤ keepTarget）

    func testOverflowTriggersWindowRebuild() async throws {
        let backend = RecordingFakeBackend(maxContextTokens: 100)
        let session = KVCacheSession(maxContextTokens: 100, keepTargetTokens: 50, backend: backend)

        _ = try await session.prefillIncremental(Array(1...60))    // 60 ≤ 100 直通
        let receipt = try await session.prefillIncremental(Array(61...105))
        // projected = 105 > 100，45 ≤ keepTarget → 滑窗重建保留 50。
        XCTAssertTrue(receipt.rebuiltFirst)
        XCTAssertEqual(receipt.cacheOffset, 0)
        XCTAssertEqual(session.cachedPrefixLength, 50)
        XCTAssertEqual(session.generation, 1)
        // 重建窗口 = [旧缓存 + 新增] 的末尾 50 = 56...105。
        XCTAssertEqual(backend.reprefillWindows, [Array(56...105)])
        XCTAssertFalse(backend.resetCount > 0, "window rebuild must not reset the pool")

        // 重建后追加从 keepTarget 起点继续（positions 连续）。
        let next = try await session.prefillIncremental(Array(106...110))
        XCTAssertEqual(next.cacheOffset, 50)
        XCTAssertEqual(next.positions, 50..<55)
        XCTAssertEqual(next.attendableCounts, Array(51...55))
    }

    // MARK: 全量重置（单块新增超过保留目标）

    func testOversizedChunkFallsBackToFullReset() async throws {
        let backend = RecordingFakeBackend(maxContextTokens: 100)
        let session = KVCacheSession(maxContextTokens: 100, keepTargetTokens: 50, backend: backend)
        _ = try await session.prefillIncremental(Array(1...90))

        let receipt = try await session.prefillIncremental(Array(101...160))
        // 60 > keepTarget 50 → reset 后对新增内容重新 prefill。
        XCTAssertTrue(receipt.rebuiltFirst)
        XCTAssertEqual(receipt.cacheOffset, 0)
        XCTAssertEqual(receipt.positions, 0..<60)
        XCTAssertEqual(session.cachedPrefixLength, 60)
        XCTAssertEqual(session.generation, 1)
        XCTAssertEqual(backend.resetCount, 1)
        XCTAssertEqual(backend.writeOffsets, [0, 0], "first append at 0, post-reset append at 0")
    }

    // MARK: 失效信号懒生效（音频不连续 → 必须重置）

    func testInvalidationLazilyResetsBeforeNextAppend() async throws {
        let backend = RecordingFakeBackend(maxContextTokens: 100)
        let session = KVCacheSession(maxContextTokens: 100, keepTargetTokens: 50, backend: backend)
        _ = try await session.prefillIncremental(Array(1...20))
        XCTAssertEqual(backend.resetCount, 0)

        // 环形缓冲覆盖丢弃 → 外部信号失效。
        session.invalidate(.streamDiscontinuity)
        // 失效在下次追加前生效（懒执行，不打断当前 pass）。
        let receipt = try await session.prefillIncremental(Array(1...5))
        XCTAssertEqual(backend.resetCount, 1)
        XCTAssertFalse(receipt.rebuiltFirst, "reset is transparent: append proceeds at offset 0")
        XCTAssertEqual(receipt.cacheOffset, 0)
        XCTAssertEqual(receipt.positions, 0..<5)
        XCTAssertEqual(session.cachedPrefixLength, 5)
        XCTAssertEqual(session.generation, 1)
    }

    // MARK: 规划纯函数边界

    func testPlanAppendBoundaries() async throws {
        let backend = RecordingFakeBackend(maxContextTokens: 100)
        let session = KVCacheSession(maxContextTokens: 100, keepTargetTokens: 50, backend: backend)
        XCTAssertEqual(session.planAppend(newTokenCount: 0), .none)
        XCTAssertEqual(session.planAppend(newTokenCount: 50), .none)   // 0+50 ≤ 100
        _ = try await session.prefillIncremental(Array(1...80))
        XCTAssertEqual(session.planAppend(newTokenCount: 15), .none)   // 80+15 = 95 ≤ 100
        // 80+30 = 110 > 100，30 ≤ keepTarget 50 → 滑窗裁 evict = 110−50 = 60。
        XCTAssertEqual(session.planAppend(newTokenCount: 30), .shiftWindow(evictCount: 60))
        // 60 > keepTarget 50 → 只能全量重建。
        XCTAssertEqual(session.planAppend(newTokenCount: 60), .resetAll)
    }
}
