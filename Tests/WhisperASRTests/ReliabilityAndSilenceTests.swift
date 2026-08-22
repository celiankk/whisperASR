import XCTest
@testable import WhisperASR

/// 第十二轮对标落地项回归：看门狗基线相对制、输入补零桶化、
/// 自适应/渐进静音纯函数。
final class ReliabilityAndSilenceTests: XCTestCase {

    // MARK: #10 看门狗基线相对制

    func testBaselineRelativeCeiling() {
        var policy = MemoryReclaimPolicy(ceilingBytes: 6_000_000_000)
        policy.baselineBytes = 2_000_000_000
        // 生效上限 = min(基线+2GB, 绝对 6GB) = 4GB。
        XCTAssertEqual(policy.effectiveCeiling, 4_000_000_000)
    }

    func testBaselineCappedByAbsolute() {
        var policy = MemoryReclaimPolicy(ceilingBytes: 3_000_000_000)
        policy.baselineBytes = 2_500_000_000
        // 基线+2GB=4.5GB 超绝对上限 → 取 3GB（基线制不得更宽松）。
        XCTAssertEqual(policy.effectiveCeiling, 3_000_000_000)
    }

    func testNoBaselineFallsBackToAbsolute() {
        let policy = MemoryReclaimPolicy(ceilingBytes: 5_000_000_000)
        XCTAssertNil(policy.baselineBytes)
        XCTAssertEqual(policy.effectiveCeiling, 5_000_000_000)
    }

    func testReclaimTriggersOnBaselineDelta() {
        var policy = MemoryReclaimPolicy(ceilingBytes: 6_000_000_000)
        policy.baselineBytes = 2_000_000_000
        // footprint 4.1GB ≥ 生效 4GB → 回收（绝对制 6GB 下不会触发）。
        XCTAssertTrue(policy.shouldReclaim(
            footprintBytes: 4_100_000_000, asrIdle: true, transcriptionIdle: true,
            lastReclaim: nil))
        XCTAssertFalse(policy.shouldReclaim(
            footprintBytes: 3_900_000_000, asrIdle: true, transcriptionIdle: true,
            lastReclaim: nil))
    }

    // MARK: #8 输入补零桶化

    func testBucketingExactMultipleUnchanged() {
        let samples = [Float](repeating: 0.1, count: 16_000)   // 1.0s
        let padded = InputBucketing.padded(samples)
        XCTAssertEqual(padded.count, 16_000)
        XCTAssertTrue(padded.elementsEqual(samples))
    }

    func testBucketingPadsToNextQuantum() {
        let samples = [Float](repeating: 0.1, count: 9_000)   // 0.5625s
        let padded = InputBucketing.padded(samples)
        XCTAssertEqual(padded.count, 16_000, "补到 1.0s 桶")
        // 尾部补零、原样本不变。
        XCTAssertEqual(Array(padded.prefix(9_000)), samples)
        XCTAssertTrue(padded.suffix(7_000).allSatisfy { $0 == 0 })
    }

    func testBucketingShortInputPadded() {
        let padded = InputBucketing.padded([0.5, 0.3])
        XCTAssertEqual(padded.count, InputBucketing.quantumSamples)
    }

    func testBucketingEmptyUnchanged() {
        XCTAssertTrue(InputBucketing.padded([]).isEmpty)
    }

    // MARK: #1 自适应静音 P75

    func testAdaptiveSilenceFewSamplesUsesDefault() {
        XCTAssertEqual(ASRManager.adaptiveSilenceSeconds(from: [0.5, 0.4]), 0.3)
        XCTAssertEqual(ASRManager.adaptiveSilenceSeconds(from: []), 0.3)
    }

    func testAdaptiveSilenceP75TimesFactor() {
        // 4 样本 [0.2,0.3,0.4,1.0]：P75 = index 3（1.0）×1.2=1.2s。
        let result = ASRManager.adaptiveSilenceSeconds(from: [0.2, 0.3, 0.4, 1.0])
        XCTAssertEqual(result, 1.2, accuracy: 0.001)
    }

    func testAdaptiveSilenceClamped() {
        // P75 巨大 → 夹 2.0s；P75 极小 → 保底 0.3s。
        XCTAssertEqual(ASRManager.adaptiveSilenceSeconds(from: [5, 6, 7, 8]), 2.0, accuracy: 0.001)
        XCTAssertEqual(ASRManager.adaptiveSilenceSeconds(from: [0.01, 0.02, 0.03, 0.01]), 0.3, accuracy: 0.001)
    }

    // MARK: #2 渐进式静音系数

    func testProgressiveSilenceFactor() {
        XCTAssertEqual(ASRManager.progressiveSilenceFactor(tailSeconds: 3), 1.0)
        XCTAssertEqual(ASRManager.progressiveSilenceFactor(tailSeconds: 7), 0.5)
        XCTAssertEqual(ASRManager.progressiveSilenceFactor(tailSeconds: 12), 0.25)
    }
}
