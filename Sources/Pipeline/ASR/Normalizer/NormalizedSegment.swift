import Foundation

// MARK: - 归一化分段（NormalizedSegment）
//
// 统一识别结果层的最小显示单元：所有 ASR 引擎（whisper / qwen3asr /
// nemotron / online / apple / funasr）的输出经 ASRResultNormalizer
// 折算为本结构后进入字幕层。
//
// 字幕层规则（解耦承诺）：
// - 只消费 NormalizedASRResult，禁止出现 if whisper / if funasr / if apple；
// - 引擎差异（时间戳坐标系、增量语义、confidence 有无）由 Normalizer
//   折算为 metadata 中的正交字段（ASRTimebase / ASRMergePolicy），
//   字幕层按字段行为，不按引擎名分支。

/// 归一化分段：引擎输出的最小显示单元。
struct NormalizedSegment: Equatable, Sendable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let confidence: Float?
    let isFinal: Bool

    init(id: UUID = UUID(),
         text: String,
         startTime: TimeInterval,
         endTime: TimeInterval? = nil,
         confidence: Float? = nil,
         isFinal: Bool) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isFinal = isFinal
    }

    /// 转字幕层现有 TranscriptionSegment（显示/持久化数据结构不变；
    /// isFinal 不进入 TranscriptionSegment——现有消费方只读 start/end/text）。
    func toTranscriptionSegment() -> TranscriptionSegment {
        TranscriptionSegment(start: startTime, end: endTime, text: text)
    }

    /// 从字幕层现有段构造（isFinal 由调用方标注；用于回迁/测试）。
    static func from(_ segment: TranscriptionSegment, isFinal: Bool) -> NormalizedSegment {
        NormalizedSegment(text: segment.text,
                          startTime: segment.start,
                          endTime: segment.end,
                          confidence: nil,
                          isFinal: isFinal)
    }
}

// MARK: - 归一化结果（NormalizedASRResult）
//
// 统一识别结果层的完整载荷：所有 ASR 引擎的输出经 ASRResultNormalizer
// 归一为本结构后进入字幕层。字幕层只消费本结构（解耦承诺）。

/// 归一化识别结果。
struct NormalizedASRResult: Equatable, Sendable {
    let segments: [NormalizedSegment]
    /// 检测/指定的语言（ISO-639-1 或 BCP-47；引擎不提供时为 nil）。
    let language: String?
    /// 产出引擎。
    let engine: ASREngineType
    /// 引擎差异元数据（时间坐标系 / 合并策略）——字幕层按此行为。
    let metadata: ASRMetadata
    /// Provider 原始整段文本（文件转录的 fullText 兼容字段；
    /// 实时链路不使用——增量语义下整段文本无意义）。
    var fullText: String = ""
    /// 真 = 本轮没有产出，因为音频**仍在聚合中**（未达发送条件），
    /// 而不是「引擎听清了、结果是空」。
    ///
    /// 调度层据此跳过字幕发布：聚合未达标时 tail 段为空，若按
    /// `.replaceTail` 提交会把 pendingTail 清空 —— 屏幕上的当前句在
    /// 每个未达标的 pass 上被抹掉（启用「音频分片：仅本地/仅在线」后
    /// 字幕随分片节奏闪烁消失）。空但非聚合（真静音）仍按空结果提交。
    var isAggregationPending: Bool = false

    init(segments: [NormalizedSegment],
         language: String?,
         engine: ASREngineType,
         metadata: ASRMetadata,
         fullText: String = "",
         isAggregationPending: Bool = false) {
        self.segments = segments
        self.language = language
        self.engine = engine
        self.metadata = metadata
        self.fullText = fullText
        self.isAggregationPending = isAggregationPending
    }

    /// 空结果（喂入为空 / 引擎暂无产出）：保留引擎与元数据，
    /// 字幕层按空段跳过显示但可依赖 metadata 做调度决策。
    static func empty(engine: ASREngineType, metadata: ASRMetadata) -> NormalizedASRResult {
        NormalizedASRResult(segments: [], language: nil, engine: engine, metadata: metadata)
    }

    /// 「聚合中、本轮无产出」占位结果（与 empty 的区别见 isAggregationPending）。
    static func aggregationPending(engine: ASREngineType,
                                   metadata: ASRMetadata) -> NormalizedASRResult {
        NormalizedASRResult(segments: [], language: nil, engine: engine,
                            metadata: metadata, isAggregationPending: true)
    }

    /// 是否含非空文本段（空文本段在 Normalizer 已丢弃，此处即「有无内容」）。
    var hasContent: Bool {
        segments.contains { !$0.text.isEmpty }
    }
}
