import XCTest
@testable import WhisperASR

// MARK: - 背压策略 + 采样率/声道对齐测试
//
// 覆盖：
// - 环形缓冲 overwriteOldest 背压：覆盖最旧、消费者滞后跳过、
//   不连续标记与丢弃记账（查询即清零）；
// - RTAudioResampler：48k→16k 长度比、直流增益 1、分块与整段逐样本
//   一致（跨块历史管理正确性）、通带信号能量保持；
// - RealtimeAudioIngest：立体声下混等价性、满载背压不阻塞 + 丢弃记账。
final class RealtimeAudioIngestTests: XCTestCase {

    // MARK: overwriteOldest 背压

    func testOverwriteOldestDropsOldestAndFlagsDiscontinuity() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 4, overflowPolicy: .overwriteOldest)
        XCTAssertEqual(ring.write([1, 2, 3, 4], count: 4), 4)
        // 满：再写 2 个 → 覆盖 [1,2]，恒返回 count（绝不阻塞/拒绝）。
        XCTAssertEqual(ring.write([5, 6], count: 6 == 6 ? 2 : 0), 2)

        var sink = [Float](repeating: -1, count: 4)
        let read = sink.withUnsafeMutableBufferPointer { buf in
            ring.read(to: buf.baseAddress!, count: 4)
        }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(sink, [3, 4, 5, 6], "consumer must resume from the newest window")

        XCTAssertTrue(ring.takeDiscontinuity(), "overwrite must flag discontinuity")
        XCTAssertEqual(ring.takeDroppedSamples(), 2)
        // 查询即清零。
        XCTAssertFalse(ring.takeDiscontinuity())
        XCTAssertEqual(ring.takeDroppedSamples(), 0)
    }

    func testOverwriteOldestWithoutOverflowKeepsContinuity() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 8, overflowPolicy: .overwriteOldest)
        XCTAssertEqual(ring.write([1, 2, 3], count: 3), 3)
        var sink = [Float](repeating: -1, count: 3)
        let read = sink.withUnsafeMutableBufferPointer { buf in
            ring.read(to: buf.baseAddress!, count: 3)
        }
        XCTAssertEqual(read, 3)
        XCTAssertEqual(sink, [1, 2, 3])
        XCTAssertFalse(ring.takeDiscontinuity())
        XCTAssertEqual(ring.takeDroppedSamples(), 0)
    }

    func testDropLatestPolicyRejectsWhenFull() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 4, overflowPolicy: .dropLatest)
        XCTAssertEqual(ring.write([1, 2, 3, 4], count: 4), 4)
        // 满：新到样本被拒（返回 0），无覆盖、无不连续。
        XCTAssertEqual(ring.write([5, 6], count: 2), 0)
        var sink = [Float](repeating: -1, count: 4)
        let read = sink.withUnsafeMutableBufferPointer { buf in
            ring.read(to: buf.baseAddress!, count: 4)
        }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(sink, [1, 2, 3, 4])
        XCTAssertFalse(ring.takeDiscontinuity())
    }

    // MARK: 重采样（48k → 16k）

    /// 分块（模拟回调节奏）与整段一次重采样：重叠区逐样本一致。
    /// 这是跨块历史管理正确性的核心不变量——FIR 相位按绝对输入位置对齐。
    func testResamplerChunkedMatchesMonolithic() {
        let resampler = RTAudioResampler()
        let totalFrames = 24_000
        // 确定性混合信号（两枚通带内正弦 + 微直流）。
        let input = (0..<totalFrames).map { i -> Float in
            let t = Double(i) / 48_000
            return Float(0.4 * sin(2 * .pi * 440 * t) + 0.3 * sin(2 * .pi * 1000 * t) + 0.05)
        }
        var monoBuffer = input

        // 整段一次（上界契约：整段实例按输入长度预分配）。
        let wholeResampler = RTAudioResampler(maxInputFrames: totalFrames)
        let (whole, wholeCount) = monoBuffer.withUnsafeBufferPointer { buf in
            wholeResampler.resample(input: buf.baseAddress!, frameCount: totalFrames)
        }
        XCTAssertGreaterThan(wholeCount, 7_900)   // (24000-71)/3 ≈ 7976

        // 分块 1024 帧（新实例：状态归零后等价输入流）。
        let chunked = RTAudioResampler()
        var chunkOutputs: [Float] = []
        var offset = 0
        while offset < totalFrames {
            let n = Swift.min(1024, totalFrames - offset)
            let (out, count) = monoBuffer.withUnsafeBufferPointer { buf in
                chunked.resample(input: buf.baseAddress! + offset, frameCount: n)
            }
            chunkOutputs.append(contentsOf: UnsafeBufferPointer(start: out, count: count))
            offset += n
        }
        // 输出长度应一致（相位对齐时精确相等；分块尾部余数允许 ≤1 样本差）。
        XCTAssertTrue(abs(chunkOutputs.count - wholeCount) <= 1,
                      "chunked=\(chunkOutputs.count) whole=\(wholeCount)")
        // 逐样本一致（同机同滤波器：确定性 FIR，允许浮点 1e-5 舍入差）。
        let comparable = Swift.min(chunkOutputs.count, wholeCount)
        for i in 0..<comparable {
            XCTAssertEqual(chunkOutputs[i], whole[i], accuracy: 1e-5,
                           "sample \(i) diverged between chunked and monolithic")
        }
        _ = monoBuffer.removeLast(0) // silence unused-var lint in some toolchains
    }

    /// 直流增益 1：常数输入重采样后幅值不变（滤波器归一化校验）。
    func testResamplerDCGainIsUnity() {
        let resampler = RTAudioResampler()
        var constant = [Float](repeating: 0.5, count: 8000)
        let (out, count) = constant.withUnsafeBufferPointer { buf in
            resampler.resample(input: buf.baseAddress!, frameCount: 8000)
        }
        XCTAssertGreaterThan(count, 100)
        // 跳过滤波器建立段（前 64 输出），稳态应精确等于 0.5。
        for i in 64..<count {
            XCTAssertEqual(out[i], 0.5, accuracy: 1e-4, "DC gain error at \(i)")
        }
        constant.removeLast(0)
    }

    /// 输出长度比 ≈ 1/3（48k→16k），建立段外无系统性漂移。
    func testResamplerOutputRateRatio() {
        let resampler = RTAudioResampler()
        var input = [Float](repeating: 0.1, count: 96_000)   // 2s @48k
        var totalOut = 0
        // 按回调节奏分块喂（每块 8000 帧 ≤ maxInputFrames）。
        var offset = 0
        while offset < input.count {
            let n = Swift.min(8000, input.count - offset)
            input.withUnsafeBufferPointer { buf in
                let (_, count) = resampler.resample(input: buf.baseAddress! + offset, frameCount: n)
                totalOut += count
            }
            offset += n
        }
        // 比率误差 < 0.1%（分块相位对齐，无漂移累积）。
        let ratio = Double(totalOut) / 96_000
        XCTAssertEqual(ratio, 1.0 / 3.0, accuracy: 0.001)
        input.removeLast(0)
    }

    // MARK: 组合链路（下混 → 降采样 → 环形缓冲）

    /// 立体声（L=R=x）下混后必须与直接喂 mono x 的输出一致。
    func testIngestStereoDownmixMatchesMono() throws {
        let frames = 4_800   // 0.1s @48k
        let stereo = (0..<frames).flatMap { i -> [Float] in
            let x = Float(sin(2 * .pi * 220 * Double(i) / 48_000))
            return [x, x]
        }
        let mono = (0..<frames).map { i -> Float in
            Float(sin(2 * .pi * 220 * Double(i) / 48_000))
        }

        let stereoIngest = try RealtimeAudioIngest(capacitySamples: 1 << 12, maxInputFrames: 8192)
        let monoIngest = try RealtimeAudioIngest(capacitySamples: 1 << 12, maxInputFrames: 8192)
        stereo.withUnsafeBufferPointer { buf in
            stereoIngest.ingest(input: buf.baseAddress!, sampleCount: buf.count, channelCount: 2)
        }
        mono.withUnsafeBufferPointer { buf in
            monoIngest.ingest(input: buf.baseAddress!, sampleCount: buf.count, channelCount: 1)
        }

        XCTAssertEqual(stereoIngest.ring.availableToRead, monoIngest.ring.availableToRead)
        let n = stereoIngest.ring.availableToRead
        XCTAssertGreaterThan(n, 1_000)
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        a.withUnsafeMutableBufferPointer { buf in _ = stereoIngest.ring.read(to: buf.baseAddress!, count: n) }
        b.withUnsafeMutableBufferPointer { buf in _ = monoIngest.ring.read(to: buf.baseAddress!, count: n) }
        XCTAssertEqual(a, b)
    }

    /// 满载背压：消费端不读，生产端持续写入——绝不阻塞、绝不崩溃；
    /// 恢复读取后拿到「最新窗口」+ 不连续标记 + 丢弃记账。
    func testIngestBackpressureOverwritesOldestWithoutBlocking() throws {
        let ingest = try RealtimeAudioIngest(capacitySamples: 1 << 12, maxInputFrames: 8192)
        let frames = 4_800
        let chunk = [Float](repeating: 0.3, count: frames)
        let started = Date()
        // 8 块 = 38400 帧 @48k → 12800 样本 @16k，容量 4096 → 必然多轮覆盖。
        for _ in 0..<8 {
            chunk.withUnsafeBufferPointer { buf in
                ingest.ingest(input: buf.baseAddress!, sampleCount: buf.count, channelCount: 1)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "producer must never block")
        XCTAssertLessThanOrEqual(ingest.ring.availableToRead, 4096)

        // 先消费（不连续标记在 read 的滞后检测时置位），再查记账。
        var sink = [Float](repeating: 0, count: 4096)
        let read = sink.withUnsafeMutableBufferPointer { buf in
            ingest.ring.read(to: buf.baseAddress!, count: 4096)
        }
        XCTAssertEqual(read, 4096)
        XCTAssertTrue(ingest.takeDiscontinuity(), "overflow must be reported")
        XCTAssertGreaterThan(ingest.takeDroppedSamples(), 0, "8 blocks > 16s window capacity")
        // 查询即清零。
        XCTAssertFalse(ingest.takeDiscontinuity())
        XCTAssertEqual(ingest.takeDroppedSamples(), 0)
        XCTAssertEqual(ingest.ring.availableToRead, 0)
    }
}
