import XCTest
@testable import WhisperASR

// MARK: - ASRResultNormalizer 单测（统一识别结果层）
//
// 覆盖规格第七节的四引擎形态（纯数据层，无需真机模型）：
// - Whisper 实时字幕：多段时间戳 + confidence 缺失；
// - FunASR SenseVoice 实时字幕：offline final 整段；
// - Qwen3-ASR 文件识别：chunk/文件结果整段替换策略；
// - Apple Speech：增量 partial / final 修正、confidence 均值。
// 核心断言：归一输出只携带 metadata，不携带引擎分支语义——
// 字幕层按 mergePolicy 行为即可正确渲染。

final class ASRResultNormalizerTests: XCTestCase {
    private let stateless = ASRMetadata.stateless
    private let streaming = ASRMetadata.streaming

    // MARK: Whisper 实时字幕

    func testWhisperMultiSegmentPreservesTimestamps() throws {
        let result = TranscriptionResult(
            text: "hello world",
            segments: [
                TranscriptionSegment(start: 0.0, end: 1.2, text: " hello "),
                TranscriptionSegment(start: 1.2, end: nil, text: "world"),
                TranscriptionSegment(start: 2.0, end: 2.5, text: "   "),  // 空白段丢弃
            ],
            detectedLanguage: "en")
        let normalized = ASRResultNormalizer.normalize(
            result, engine: .whisper, metadata: stateless)

        XCTAssertEqual(normalized.engine, .whisper)
        XCTAssertEqual(normalized.language, "en")
        XCTAssertEqual(normalized.metadata, stateless)
        XCTAssertEqual(normalized.segments.count, 2)
        XCTAssertEqual(normalized.segments[0].startTime, 0.0, accuracy: 0.0001)
        let firstEnd = try XCTUnwrap(normalized.segments[0].endTime)
        XCTAssertEqual(firstEnd, 1.2, accuracy: 0.0001)
        XCTAssertEqual(normalized.segments[0].text, "hello")
        XCTAssertNil(normalized.segments[0].confidence)  // whisper chunk 无 confidence 来源
        XCTAssertTrue(normalized.segments[0].isFinal)
        XCTAssertNil(normalized.segments[1].endTime)
    }

    // MARK: FunASR

    func testFunASRSenseVoiceOfflineFinalIsReplaceTail() throws {
        // SenseVoice offline：每轮独立转录整个 tail → replaceTail。
        let asr = ASRResult(text: "今天天气不错", isFinal: true,
                            language: "zh", confidence: nil,
                            timestamp: (0, 2.4))
        let normalized = ASRResultNormalizer.normalize(
            asr, engine: .funasr,
            metadata: ASRMetadata.default(isStreamingEngine: false))

        XCTAssertEqual(normalized.metadata.mergePolicy, .replaceTail)
        XCTAssertEqual(normalized.metadata.timebase, .chunkRelative)
        let segment = try XCTUnwrap(normalized.segments.first)
        let senseVoiceEnd = try XCTUnwrap(segment.endTime)
        XCTAssertEqual(senseVoiceEnd, 2.4, accuracy: 0.0001)
        XCTAssertTrue(segment.isFinal)
        XCTAssertEqual(segment.text, "今天天气不错")
    }

    func testFunASRParaformerStreamingIncrementalIsAppendIncrement() throws {
        // paraformer-streaming：只返回新增文本（partial）→ appendIncrement。
        let asr = ASRResult(text: "继续说", isFinal: false,
                            language: "zh", confidence: nil,
                            timestamp: (0, nil))
        let normalized = ASRResultNormalizer.normalize(
            asr, engine: .funasr,
            metadata: ASRMetadata.default(isStreamingEngine: true))

        XCTAssertEqual(normalized.metadata.mergePolicy, .appendIncrement)
        XCTAssertEqual(normalized.metadata.timebase, .sessionStart)
        let segment = try XCTUnwrap(normalized.segments.first)
        XCTAssertFalse(segment.isFinal)
        XCTAssertNil(segment.endTime)
    }

    // MARK: Qwen3-ASR 文件识别

    func testQwenFileTranscriptionReplaceTail() {
        let result = TranscriptionResult(
            text: "测试文本",
            segments: [TranscriptionSegment(start: 0.5, end: 3.5, text: "测试文本")],
            detectedLanguage: nil)  // Qwen 不回传检测语言
        let normalized = ASRResultNormalizer.normalize(
            result, engine: .qwen3asr, metadata: stateless)

        XCTAssertEqual(normalized.engine, .qwen3asr)
        XCTAssertNil(normalized.language)
        XCTAssertEqual(normalized.metadata.mergePolicy, .replaceTail)
        XCTAssertEqual(normalized.segments.count, 1)
        XCTAssertEqual(normalized.segments[0].startTime, 0.5, accuracy: 0.0001)
    }

    // MARK: Apple Speech

    func testApplePartialAndFinalCorrection() throws {
        // partial：confidence 均值 + 段时长保留。
        let partial = ASRResult(text: "ta pop", isFinal: false,
                                language: "en-US", confidence: 0.82,
                                timestamp: (1.0, 2.5))
        let normalizedPartial = ASRResultNormalizer.normalize(
            partial, engine: .apple, metadata: streaming)
        XCTAssertEqual(normalizedPartial.metadata.mergePolicy, .appendIncrement)
        let partialSegment = try XCTUnwrap(normalizedPartial.segments.first)
        XCTAssertFalse(partialSegment.isFinal)
        let confidence = try XCTUnwrap(partialSegment.confidence)
        XCTAssertEqual(confidence, 0.82, accuracy: 0.0001)
        let endTime = try XCTUnwrap(partialSegment.endTime)
        XCTAssertEqual(endTime, 2.5, accuracy: 0.0001)

        // final 修正（"ta pop"→"pop"）：文本直接透传，isFinal=true。
        let final = ASRResult(text: "pop", isFinal: true,
                              language: "en-US", confidence: 0.9,
                              timestamp: (1.0, 2.5))
        let normalizedFinal = ASRResultNormalizer.normalize(
            final, engine: .apple, metadata: streaming)
        let finalSegment = try XCTUnwrap(normalizedFinal.segments.first)
        XCTAssertTrue(finalSegment.isFinal)
        XCTAssertEqual(finalSegment.text, "pop")
    }

    // MARK: 空结果与回迁

    func testEmptyTextProducesNoSegmentsButKeepsMetadata() {
        let asr = ASRResult(text: "", isFinal: true, language: nil,
                            confidence: nil, timestamp: (0, nil))
        let normalized = ASRResultNormalizer.normalize(asr, engine: .online, metadata: stateless)
        XCTAssertFalse(normalized.hasContent)
        XCTAssertTrue(normalized.segments.isEmpty)
        XCTAssertEqual(normalized.engine, .online)
        XCTAssertEqual(normalized.metadata, stateless)
    }

    func testToTranscriptionSegmentsRoundTripKeepsDisplayFields() {
        let asr = ASRResult(text: "你好世界", isFinal: true, language: "zh",
                            confidence: 0.7, timestamp: (0, 2))
        let normalized = ASRResultNormalizer.normalize(asr, engine: .funasr, metadata: stateless)
        let back = ASRResultNormalizer.toTranscriptionSegments(normalized)
        XCTAssertEqual(back, [TranscriptionSegment(start: 0, end: 2, text: "你好世界")])
    }

    // MARK: 聚合占位（保护屏幕上的当前句）

    func testAggregationPendingIsDistinctFromEmpty() {
        // 「聚合中」与「听清了但结果为空」语义不同：前者调度层必须跳过发布，
        // 否则每个未达标的 pass 都会用空 tail 清掉正在显示的字幕。
        let pending = NormalizedASRResult.aggregationPending(
            engine: .whisper, metadata: stateless)
        let empty = NormalizedASRResult.empty(engine: .whisper, metadata: stateless)

        XCTAssertTrue(pending.isAggregationPending)
        XCTAssertFalse(empty.isAggregationPending, "空结果不是聚合占位（真静音要照常提交）")
        XCTAssertFalse(pending.hasContent)
        XCTAssertFalse(empty.hasContent)
        XCTAssertEqual(pending.metadata, empty.metadata)
        XCTAssertEqual(pending.engine, empty.engine)
    }
}
