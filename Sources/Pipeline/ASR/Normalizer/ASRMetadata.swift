import Foundation

// MARK: - 归一化元数据（ASRMetadata）
//
// 引擎差异的正交字段：Normalizer 把「各引擎输出语义的不同」折算为这里的
// 枚举值随结果下发，字幕层按字段行为、不按引擎名分支（解耦承诺，
// 见 NormalizedSegment.swift 头注）。
//
// 规格命名桥接：规格中的 ASREngineType 即现有 ASRProviderEngine
// （whisper / qwen3asr / nemotron / online / apple / funasr）——
// 不另造重复枚举。

/// 引擎标识（统一识别结果层的类型别名）。
typealias ASREngineType = ASRProviderEngine

/// 分段时间戳坐标系（startTime 的参照原点）。
enum ASRTimebase: Equatable, Sendable {
    /// 相对当前分块起点（无状态引擎每块独立转录，start=0 即块首）。
    /// 调用方负责加上分块的绝对偏移（ASRManager 现行 timeOffset 行为）。
    case chunkRelative
    /// 相对流式会话启动点（Apple Speech / FunASR-streaming：音频持续喂入
    /// 同一会话，时间戳自会话起算）。当前管线会话与录制同生命周期，
    /// 调用方同样加尾部偏移；字段用于区分语义、支撑未来绝对时间轴引擎。
    case sessionStart
}

/// 字幕层合并策略（替代字幕层的 if apple / if funasr 判断）。
enum ASRMergePolicy: Equatable, Sendable {
    /// 整段替换：引擎每轮重转录整个未封口 tail，本轮结果直接替换
    /// pendingTail（whisper / Qwen / Nemotron / 在线 / FunASR offline）。
    case replaceTail
    /// 增量并入：引擎只返回新增文本，跨轮累积为单一「当前句」段
    /// （Apple Speech / FunASR paraformer-streaming）。整段替换会把
    /// 当前句前半部分丢掉（只剩最新碎片），必须累积。
    case appendIncrement
}

/// 随 NormalizedASRResult 下发的元数据快照。
struct ASRMetadata: Equatable, Sendable {
    /// 分段时间戳坐标系。
    let timebase: ASRTimebase
    /// 字幕层合并策略。
    let mergePolicy: ASRMergePolicy

    /// 无状态引擎的默认元数据（chunk 相对时间轴 + 整段替换）。
    static let stateless = ASRMetadata(timebase: .chunkRelative, mergePolicy: .replaceTail)

    /// 流式引擎的默认元数据（会话时间轴 + 增量并入）。
    static let streaming = ASRMetadata(timebase: .sessionStart, mergePolicy: .appendIncrement)

    /// 按引擎喂音语义推导默认元数据：isStreamingEngine=true（音频持续喂入
    /// 同一会话、只返回新增文本）走增量并入，否则整段替换。
    /// Normalizer 是唯一允许按引擎分支的位置；字幕层只看本字段。
    static func `default`(isStreamingEngine: Bool) -> ASRMetadata {
        isStreamingEngine ? .streaming : .stateless
    }
}
