import Foundation

// MARK: - 识别结果归一化器（ASRResultNormalizer）
//
// 统一识别结果层的唯一转换收口：
//
//   ASRProvider（各引擎内部推理逻辑不动）
//         ↓ 统一中间结果 ASRResult / TranscriptionResult
//   ASRResultNormalizer（本文件：唯一允许按引擎分支的位置）
//         ↓
//   NormalizedASRResult
//         ↓
//   SubtitleManager（只按 metadata 行为，禁止 if whisper / if funasr / if apple）
//
// 各引擎差异的处理职责：
// - whisper：segment timestamp 保留、confidence 缺失补 nil；
// - FunASR：streaming（paraformer-streaming 增量）与 final（offline 整段）
//   按 isStreamingEngine 折算 mergePolicy；
// - Apple Speech：段时长（start/end）与 confidence 均值保留；
// - Qwen/Nemotron/在线：chunk 结果整段替换策略。
// 最终全部输出 NormalizedSegment。

enum ASRResultNormalizer {
    /// 引擎 → 默认元数据（isStreamingEngine 是 Provider 协议已声明的
    /// 喂音语义，Normalizer 据此折算字幕合并策略）。
    static func metadata(for engine: ASREngineType, isStreamingEngine: Bool) -> ASRMetadata {
        .default(isStreamingEngine: isStreamingEngine)
    }

    /// 归一 Provider 的统一 chunk 输出（ASRResult：text/isFinal/confidence/
    /// timestamp 齐全，是信息最全的输入形态——优先走本入口）。
    /// 单文本结果折叠为单段；isFinal 直接保留给字幕层。
    static func normalize(_ result: ASRResult,
                          engine: ASREngineType,
                          metadata: ASRMetadata) -> NormalizedASRResult {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments: [NormalizedSegment] = trimmed.isEmpty
            ? []
            : [NormalizedSegment(
                text: trimmed,
                startTime: result.timestamp.start,
                endTime: result.timestamp.end,
                confidence: result.confidence,
                isFinal: result.isFinal)]
        return NormalizedASRResult(
            segments: segments,
            language: result.language,
            engine: engine,
            metadata: metadata)
    }

    /// 归一多段时间戳结果（whisper 文件转录 / verbose_json 形态）：
    /// 每段独立保留时间戳与文本，confidence 无来源补 nil。
    static func normalize(_ result: TranscriptionResult,
                          engine: ASREngineType,
                          metadata: ASRMetadata) -> NormalizedASRResult {
        let segments = result.segments.compactMap { segment -> NormalizedSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return NormalizedSegment(
                text: text,
                startTime: segment.start,
                endTime: segment.end,
                confidence: nil,
                // 多段完整结果（无 partial 流）：视为 final。
                isFinal: true)
        }
        return NormalizedASRResult(
            segments: segments,
            language: result.detectedLanguage,
            engine: engine,
            metadata: metadata)
    }

    /// 归一单段增量结果（Apple Speech / paraformer-streaming 的实时路径：
    /// 上层已把 ASRResult 折成 TranscriptionSegment，isFinal 由调用方标注）。
    static func normalize(segment: TranscriptionSegment,
                          isFinal: Bool,
                          language: String?,
                          confidence: Float?,
                          engine: ASREngineType,
                          metadata: ASRMetadata) -> NormalizedASRResult {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments: [NormalizedSegment] = text.isEmpty
            ? []
            : [NormalizedSegment(
                text: text,
                startTime: segment.start,
                endTime: segment.end,
                confidence: confidence,
                isFinal: isFinal)]
        return NormalizedASRResult(
            segments: segments,
            language: language,
            engine: engine,
            metadata: metadata)
    }

    /// 回迁字幕层现有数据结构（显示/持久化不变；isFinal 信息在转换中
    /// 不再需要——字幕层现有消费方只读 start/end/text）。
    static func toTranscriptionSegments(_ result: NormalizedASRResult) -> [TranscriptionSegment] {
        result.segments.map { $0.toTranscriptionSegment() }
    }
}
