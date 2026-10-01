import XCTest
@testable import WhisperASR

// MARK: - 持久化系统测试（SQLite 索引 + Opus 归档）
//
// 覆盖：PRAGMA 生效校验、范围游标分页无重不漏、万条检索性能（<2ms）、
// Opus 压缩率 ≥90%、归档偏移连续性与包帧结构完整性、索引↔归档联动映射。
final class TranscriptionPersistenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persist-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: SQLite 索引层

    func testWALModeActive() throws {
        let store = try TranscriptionIndexStore(
            path: tempDir.appendingPathComponent("index.db").path)
        // WAL 校验在 init 内已断言（journal_mode 必须返回 wal）。
        _ = store
        // WAL 副产物文件存在性（-wal/-shm 在首次写后出现）。
        try store.appendSegment(sessionID: "s1", startTimestamp: 0,
                                text: "warm", opusOffset: 0, opusLength: 10)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("index.db-wal").path),
            "WAL mode must create -wal file")
    }

    func testInsertAndRangeQueryRoundtrip() throws {
        let store = try TranscriptionIndexStore(
            path: tempDir.appendingPathComponent("index.db").path)
        let expected: [(Double, String)] = [
            (0.0, "会议开始"), (1.5, "第一句话"), (3.2, "第二句话"),
            (7.8, "第三句话"), (12.0, "结束"),
        ]
        for (t, text) in expected {
            _ = try store.appendSegment(sessionID: "meeting", startTimestamp: t,
                                        text: text, opusOffset: Int64(t * 3000),
                                        opusLength: 3000)
        }
        XCTAssertEqual(try store.segmentCount(sessionID: "meeting"), 5)

        // 全范围检索：按时间升序、字段完整。
        let all = try store.querySegments(sessionID: "meeting", fromTime: 0, toTime: 100)
        XCTAssertEqual(all.map(\.textContent), expected.map(\.1))
        XCTAssertEqual(all.map(\.startTimestamp), expected.map(\.0))
        XCTAssertEqual(all[2].opusOffset, 9600)

        // 时间子范围。
        let mid = try store.querySegments(sessionID: "meeting", fromTime: 2.0, toTime: 8.0)
        XCTAssertEqual(mid.map(\.textContent), ["第二句话", "第三句话"])

        // 会话隔离。
        XCTAssertEqual(try store.segmentCount(sessionID: "other"), 0)
    }

    /// 游标分页：keyset 翻页覆盖全部记录，无重复、无遗漏。
    func testCursorPaginationNoDupNoGap() throws {
        let store = try TranscriptionIndexStore(
            path: tempDir.appendingPathComponent("index.db").path)
        let count = 1000
        for i in 0..<count {
            _ = try store.appendSegment(sessionID: "s", startTimestamp: Double(i) * 0.25,
                                        text: "seg \(i)",
                                        opusOffset: Int64(i) * 100, opusLength: 100)
        }
        var collected: [TranscriptionSegmentRecord] = []
        var cursorTS = -Double.infinity
        var cursorID: Int64 = 0
        while true {
            let page = try store.querySegments(sessionID: "s", fromTime: 0, toTime: 1e9,
                                               limit: 137,
                                               cursorTimestamp: cursorTS, cursorID: cursorID)
            guard let last = page.last else { break }
            collected += page
            cursorTS = last.startTimestamp
            cursorID = last.id
        }
        XCTAssertEqual(collected.count, count)
        XCTAssertEqual(collected.map(\.id), Array(1...Int64(count)), "strictly ordered, no dup/gap")
    }

    /// 性能：万条记录下时间范围游标查询中位耗时 < 2ms（需求指标）。
    func testTenThousandRecordsRangeQueryUnder2ms() throws {
        let store = try TranscriptionIndexStore(
            path: tempDir.appendingPathComponent("index.db").path)
        let count = 10_000
        try store.executeInTransaction {
            for i in 0..<count {
                _ = try store.appendSegment(sessionID: "bench",
                                            startTimestamp: Double(i) * 0.25,
                                            text: "transcript segment number \(i) 会议内容",
                                            opusOffset: Int64(i) * 120,
                                            opusLength: 120)
            }
        }
        XCTAssertEqual(try store.segmentCount(sessionID: "bench"), count)

        // 预热（页缓存/mmap 就位）。
        _ = try store.querySegments(sessionID: "bench", fromTime: 0, toTime: 1e9, limit: 200)
        _ = try store.querySegments(sessionID: "bench", fromTime: 100, toTime: 1e9, limit: 200)

        var durations: [Double] = []
        for round in 0..<30 {
            let from = Double(round * 300) * 0.25
            let clock = ContinuousClock()
            let start = clock.now
            let rows = try store.querySegments(sessionID: "bench", fromTime: from,
                                               toTime: from + 100, limit: 200)
            let elapsed = clock.now - start
            let ms = Double(elapsed.components.seconds) * 1e3
                + Double(elapsed.components.attoseconds) / 1e15
            durations.append(ms)
            XCTAssertEqual(rows.count, 200)
        }
        durations.sort()
        let median = durations[durations.count / 2]
        XCTAssertLessThan(median, 2.0, "median query \(median)ms must be < 2ms @10k rows")
    }

    func testTextSearch() throws {
        let store = try TranscriptionIndexStore(
            path: tempDir.appendingPathComponent("index.db").path)
        _ = try store.appendSegment(sessionID: "s", startTimestamp: 0, text: "今天讨论预算",
                                    opusOffset: 0, opusLength: 100)
        _ = try store.appendSegment(sessionID: "s", startTimestamp: 1, text: "明天讨论排期",
                                    opusOffset: 100, opusLength: 100)
        let hits = try store.searchSegments(sessionID: "s", contains: "预算")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].textContent, "今天讨论预算")
    }

    // MARK: Opus 归档层

    func testOpusArchiveCompressionAndOffsets() throws {
        let archiveURL = tempDir.appendingPathComponent("audio.opus")
        let archiver = try OpusAudioArchiver(fileURL: archiveURL)
        // 5 秒正弦（模拟语音），分 1s 块喂入。
        let framesPerSecond = 16_000
        var chunk = [Float](repeating: 0, count: framesPerSecond)
        var phase = 0.0
        for i in 0..<framesPerSecond {
            chunk[i] = Float(0.35 * sin(phase))
            phase += 2 * .pi * 220 / 16000
        }
        var results: [OpusAppendResult] = []
        for _ in 0..<5 {
            let r = try chunk.withUnsafeBufferPointer { buf in
                try archiver.append(pcm: buf.baseAddress!, frameCount: framesPerSecond)
            }
            results.append(r)
        }
        XCTAssertEqual(archiver.totalPCMFrames, 5 * framesPerSecond)
        XCTAssertEqual(archiver.archivedDuration, 5.0, accuracy: 0.01)

        // 压缩率：归档字节 / 原始 Float PCM ≤ 10%（≥90% 压缩）。
        let pcmBytes = 5 * framesPerSecond * 4
        XCTAssertGreaterThan(archiver.totalArchivedBytes, 1000, "must produce real bytes")
        let ratio = Double(archiver.totalArchivedBytes) / Double(pcmBytes)
        XCTAssertLessThanOrEqual(ratio, 0.10, "compression ratio \(ratio)")

        // 偏移连续性：每段 offset 接续前段 offset+length；末段终点 = 总字节。
        var expectedOffset: Int64 = 0
        for r in results {
            XCTAssertEqual(r.offset, expectedOffset)
            expectedOffset += Int64(r.length)
        }
        XCTAssertEqual(expectedOffset, archiver.totalArchivedBytes)

        // 帧结构完整性：按 [UInt16 BE 长度][包] 逐包走查，终点 = 文件大小。
        let fileBytes = try Data(contentsOf: archiveURL)
        XCTAssertEqual(fileBytes.count, Int(archiver.totalArchivedBytes))
        var cursor = 0
        var packetCount = 0
        while cursor < fileBytes.count {
            let len = (Int(fileBytes[cursor]) << 8) | Int(fileBytes[cursor + 1])
            cursor += 2 + len
            packetCount += 1
        }
        XCTAssertEqual(cursor, fileBytes.count, "framing must be self-consistent")
        XCTAssertGreaterThan(packetCount, 50, "5s @ 60ms frames ≈ 83 packets")
    }

    // MARK: 索引 ↔ 归档联动

    func testIndexMapsArchiveRanges() throws {
        let dbPath = tempDir.appendingPathComponent("index.db").path
        let archiveURL = tempDir.appendingPathComponent("audio.opus")
        let store = try TranscriptionIndexStore(path: dbPath)
        let archiver = try OpusAudioArchiver(fileURL: archiveURL)

        let segments: [(Double, String, Double)] = [
            (0.0, "开场问候", 2.0),
            (2.0, "讨论项目进度", 3.0),
            (5.0, "总结行动项", 2.5),
        ]
        for (start, text, duration) in segments {
            let frames = Int(duration * 16000)
            var pcm = [Float](repeating: 0.2, count: frames)
            for i in 0..<frames { pcm[i] = Float(0.2 * sin(Double(i) * 0.05)) }
            let r = try pcm.withUnsafeBufferPointer { buf in
                try archiver.append(pcm: buf.baseAddress!, frameCount: frames)
            }
            _ = try store.appendSegment(sessionID: "live", startTimestamp: start,
                                        text: text, opusOffset: r.offset,
                                        opusLength: Int64(r.length))
        }
        let rows = try store.querySegments(sessionID: "live", fromTime: 0, toTime: 100)
        XCTAssertEqual(rows.count, 3)
        // 区间互不重叠且严格递增（音频还原的先决条件）。
        for (prev, next) in zip(rows, rows.dropFirst()) {
            XCTAssertEqual(next.opusOffset, prev.opusOffset + prev.opusLength)
        }
        XCTAssertEqual(rows.last!.opusOffset + rows.last!.opusLength,
                       archiver.totalArchivedBytes)
    }
}
