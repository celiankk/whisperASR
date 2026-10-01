import XCTest
@testable import WhisperASR

// MARK: - SPSC 无锁环形缓冲单测
//
// 覆盖：容量校验（2 的幂次方）、顺序保持、环形回绕分段拷贝、
// 满/空的部分读写语义、接口契约（返回实际接受/读取数），
// 以及双线程压力下的无损顺序流（SPSC 契约成立时的核心不变量）。
final class SPSCFloatRingBufferTests: XCTestCase {

    // MARK: 容量校验

    func testRejectsNonPowerOfTwoCapacity() {
        XCTAssertThrowsError(try SPSCFloatRingBuffer(capacity: 0))
        XCTAssertThrowsError(try SPSCFloatRingBuffer(capacity: -8))
        XCTAssertThrowsError(try SPSCFloatRingBuffer(capacity: 3))
        XCTAssertThrowsError(try SPSCFloatRingBuffer(capacity: 1000))
        XCTAssertNoThrow(try SPSCFloatRingBuffer(capacity: 1))
        XCTAssertNoThrow(try SPSCFloatRingBuffer(capacity: 1024))
    }

    // MARK: 基本往返（顺序保持）

    func testWriteReadRoundTripPreservesOrder() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 8)
        let source: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let written = ring.write(source, count: source.count)  // 数组按接口要求转指针
        XCTAssertEqual(written, source.count)
        XCTAssertEqual(ring.availableToRead, source.count)

        var destination = [Float](repeating: -1, count: source.count)
        let read = destination.withUnsafeMutableBufferPointer { buf in
            ring.read(to: buf.baseAddress!, count: buf.count)
        }
        XCTAssertEqual(read, source.count)
        XCTAssertEqual(destination, source)
        XCTAssertEqual(ring.availableToRead, 0)
    }

    // MARK: 环形回绕（分段拷贝核心路径）

    func testWrapAroundSegmentedCopy() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 4)
        var sink = [Float](repeating: 0, count: 4)

        // 填满 [1,2,3,4]。
        XCTAssertEqual(ring.write([1, 2, 3, 4], count: 4), 4)
        // 读 3 个 → tail 前进到下标 3，腾出 3 个余量。
        sink.withUnsafeMutableBufferPointer { buf in
            XCTAssertEqual(ring.read(to: buf.baseAddress!, count: 3), 3)
        }
        XCTAssertEqual(Array(sink.prefix(3)), [1, 2, 3])
        // 写 4 个（只有 3 个余量）：[5,6,7] 跨末端回绕（下标 3 → 0,1）。
        XCTAssertEqual(ring.write([5, 6, 7, 8], count: 4), 3)
        // 读出全部 4 个：[4,5,6,7] —— 跨边界两段拼接后顺序必须严格保持。
        sink.withUnsafeMutableBufferPointer { buf in
            XCTAssertEqual(ring.read(to: buf.baseAddress!, count: 4), 4)
        }
        XCTAssertEqual(sink, [4, 5, 6, 7])
    }

    // MARK: 满 / 空的部分语义

    func testFullBufferRejectsFurtherWrites() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 4)
        XCTAssertEqual(ring.write([1, 2, 3, 4], count: 4), 4)
        XCTAssertEqual(ring.availableToWrite, 0)
        // 满：一个样本都写不进。
        XCTAssertEqual(ring.write([9, 9], count: 2), 0)
        // 部分接受：只腾出 1 个就只收 1 个。
        var sink = [Float](repeating: 0, count: 3)
        sink.withUnsafeMutableBufferPointer { buf in
            XCTAssertEqual(ring.read(to: buf.baseAddress!, count: 1), 1)
        }
        XCTAssertEqual(ring.write([9, 9], count: 2), 1)
    }

    func testEmptyBufferReadsNothing() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 4)
        var sink = [Float](repeating: -1, count: 2)
        let read = sink.withUnsafeMutableBufferPointer { buf in
            ring.read(to: buf.baseAddress!, count: buf.count)
        }
        XCTAssertEqual(read, 0)
    }

    func testZeroCountIsNoop() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 4)
        XCTAssertEqual(ring.write([1], count: 0), 0)
        var sink = [Float](repeating: 0, count: 1)
        let read = sink.withUnsafeMutableBufferPointer { buf in
            ring.read(to: buf.baseAddress!, count: 0)
        }
        XCTAssertEqual(read, 0)
    }

    // MARK: 单帧写读交替（模拟实时回调节奏）

    func testAlternatingSmallChunksAcrossManyWraps() throws {
        let ring = try SPSCFloatRingBuffer(capacity: 64)
        var sink = [Float](repeating: 0, count: 7)
        var expected: Float = 0
        for _ in 0..<1000 {
            let chunk = (0..<7).map { _ in
                expected += 1
                return expected
            }
            XCTAssertEqual(ring.write(chunk, count: 7), 7)
            let read = sink.withUnsafeMutableBufferPointer { buf in
                ring.read(to: buf.baseAddress!, count: 7)
            }
            XCTAssertEqual(read, 7)
            XCTAssertEqual(sink, chunk)
        }
        // 1000 轮 × 7 样本远超容量 64：回绕被反复穿越，顺序零错位。
    }

    // MARK: 双线程压力（SPSC 契约下的无损顺序流）

    /// 生产者线程写入严格递增序列（随机块长），消费者线程读取并校验
    /// 连续性。核心不变量：**总量守恒 + 顺序严格一致**——任何原子配对
    /// 或分段拷贝错误都会表现为序列断裂。
    func testConcurrentProducerConsumerStress() throws {
        let capacity = 1 << 14          // 16384 样本（≈1s @16kHz）
        let ring = try SPSCFloatRingBuffer(capacity: capacity)
        let totalSamples = 1_000_000
        let chunkMax = 1400             // 模拟 HAL 回调块长（~87ms @16kHz）

        let produced = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        let consumed = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        produced.initialize(to: 0)
        consumed.initialize(to: 0)
        defer {
            produced.deallocate()
            consumed.deallocate()
        }

        // 用非结构化 Thread（测试环境，允许分配；被测代码路径零分配）。
        let producerDone = expectation(description: "producer finished")
        let consumerDone = expectation(description: "consumer finished")
        let producer = Thread {
            var nextValue: Float = 1
            var source = [Float](repeating: 0, count: chunkMax)
            while produced.pointee < totalSamples {
                let remaining = totalSamples - produced.pointee
                let n = Swift.min(Int.random(in: 1...chunkMax), remaining)
                for i in 0..<n {
                    source[i] = nextValue
                    nextValue += 1
                }
                // 满：自旋重试（模拟 HAL 线程「丢帧或等余量」的等路径）。
                var offset = 0
                while offset < n {
                    let accepted = source.withUnsafeBufferPointer { buf in
                        ring.write(buf.baseAddress! + offset, count: n - offset)
                    }
                    offset += accepted
                    if offset < n { sched_yield() }
                }
                produced.pointee += n
            }
            producerDone.fulfill()
        }

        let consumer = Thread {
            var expectedValue: Float = 1
            var sink = [Float](repeating: 0, count: chunkMax)
            while consumed.pointee < totalSamples {
                let got = sink.withUnsafeMutableBufferPointer { buf in
                    ring.read(to: buf.baseAddress!, count: buf.count)
                }
                for i in 0..<got {
                    XCTAssertEqual(sink[i], expectedValue,
                                   "sequence break at consumed=\(consumed.pointee + i)")
                    if sink[i] != expectedValue { return }
                    expectedValue += 1
                }
                consumed.pointee += got
                if got == 0 { sched_yield() }
            }
            consumerDone.fulfill()
        }

        producer.name = "spsc-producer"
        consumer.name = "spsc-consumer"
        consumer.stackSize = 1 << 20
        producer.start()
        consumer.start()
        // 等待双线程收尾（join 的 XCTest 等价物）。
        waitForExpectations(timeout: 60)

        XCTAssertEqual(produced.pointee, totalSamples)
        XCTAssertEqual(consumed.pointee, totalSamples)
        XCTAssertEqual(ring.availableToRead, 0)
    }
}
