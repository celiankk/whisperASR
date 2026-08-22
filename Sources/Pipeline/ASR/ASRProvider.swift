import Foundation

// MARK: - ASR Provider 抽象层
//
// 统一 ASR 引擎接口（1.4 渐进式重构第一步）：
//
//   TranscriptionService（引擎门面）
//         ↓
//      ASRProvider（协议）
//         ↓
//   WhisperProvider 包装 CWhisper（whisper.cpp）
//   NemotronProvider 包装 NemotronEngine（FluidAudio / Core ML）
//   QwenProvider     包装 Qwen3ASRBackend（transcribe.cpp / ggml + Metal）
//
// 输入输出数据结构（TranscriptionResult / TranscriptionSegment /
// TranscriptionError）与 1.4 完全一致，仅调整调用关系。

/// 引擎标识（日志与状态展示用）。
enum ASRProviderEngine: String, Sendable {
    case whisper
    case nemotron
    case qwen3asr
    case online
    case apple
    /// FunASR（SenseVoice / Paraformer 系，sherpa-onnx 后端）。
    case funasr
}

/// Provider 状态快照。
enum ASRProviderStatus: Sendable, Equatable {
    /// 未加载任何模型。
    case idle
    /// 模型已加载，附模型路径。
    case loaded(path: String)
}

// MARK: - 统一 ASR 输出（ASRResult）
//
// 所有 Provider 统一输出中间结果。字幕链路规则：
// - 只要 text 非空即可进入 SubtitleManager（禁止因 isFinal=false /
//   confidence 为空 / language 为空 丢弃）；
// - partial（isFinal=false）：立即显示实时字幕；
// - final（isFinal=true）：更新当前字幕。

struct ASRResult {
    let text: String
    let isFinal: Bool
    let language: String?
    let confidence: Float?
    let timestamp: (start: Double, end: Double?)
    /// 是否为 partial（isFinal 的派生）。
    var isPartial: Bool { !isFinal }

    /// 转现有 TranscriptionResult（单段；时间戳缺失时回落）。
    func toTranscriptionResult() -> TranscriptionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: trimmed,
            segments: trimmed.isEmpty
                ? []
                : [TranscriptionSegment(start: timestamp.start, end: timestamp.end, text: trimmed)],
            detectedLanguage: language
        )
    }

    /// Provider 输出日志：[ASR Result] provider= text= isFinal=
    func log(provider: String) {
        print("[ASR Result] provider=\(provider) text=\(text.debugDescription) "
            + "isFinal=\(isFinal) language=\(language ?? "nil") "
            + "confidence=\(confidence.map { String(format: "%.2f", $0) } ?? "nil")")
    }
}

/// 统一模型类型（跨引擎目录/路由/UI 的模型身份）。
/// 与 ModelCatalog 条目一一对应——后端接入（如 sherpa-onnx）按此
/// 特化运行时行为（SenseVoice CTC / Paraformer 流式等）。
enum ASRModelType: String, CaseIterable {
    // Whisper
    case whisperSmall, whisperMedium, whisperLargeTurbo
    // Qwen / Nemotron
    case qwen3ASR, nemotron
    // FunASR
    case senseVoiceSmall
    case paraformerStreaming
    case paraformerZH
    case funASRNano

    var engine: ModelEngine {
        switch self {
        case .whisperSmall, .whisperMedium, .whisperLargeTurbo: return .whisper
        case .qwen3ASR: return .qwen3asr
        case .nemotron: return .nemotron
        case .senseVoiceSmall, .paraformerStreaming, .paraformerZH, .funASRNano: return .funasr
        }
    }

    /// 是否实时推荐（设置页 FunASR 分组排序用）。
    var isRealtimeRecommended: Bool { self == .senseVoiceSmall }
}

/// 统一 ASR Provider 接口。
protocol ASRProvider: Sendable {
    /// 引擎标识。
    var engine: ASRProviderEngine { get }

    /// 引擎音频语义：
    /// - false（默认，无状态）：每块独立重转录——上层 tail 重发无副作用
    ///   （whisper / Qwen / Nemotron / 在线）；
    /// - true（流式）：音频持续喂入同一会话，**同一段音频绝不重发**——
    ///   上层 tail 重转录的重叠区间由 TranscriptionService 水位线统一
    ///   裁剪（坑 14/17 的协议化：新流式引擎只需声明此标记，
    ///   零水位线代码）。
    var isStreamingEngine: Bool { get }

    /// 预加载实时转录模型（录制开始时调用，避免首个分块等待模型加载）。
    /// 幂等：已加载同一模型时直接返回。
    func prepare() async throws

    /// 显式加载当前选择的转录模型。幂等。
    func loadModel() async throws

    /// 释放模型资源。幂等。
    func unloadModel() async

    /// 实时分块转录：16kHz 单声道 Float32 PCM（[Float] 采样）。
    /// 返回的 TranscriptionResult 时间戳相对当前分块起点（与 1.4 一致）。
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult

    /// 带绝对采样区间的分块转录：`absoluteRange` 是 samples 在录制时间轴上的
    /// 绝对位置（AudioRecorder.accumulatedSampleCount 坐标系）。
    /// 无状态引擎（whisper 等）忽略区间；流式引擎（Apple Speech）用它做
    /// 水位线去重——上层 tail 重转录会重发已喂过的音频，直接 append 会
    /// 造成同一段音频被识别多次。nil 表示调用方无法提供位置（按旧行为全量喂入）。
    func transcribeChunk(samples: [Float], absoluteRange: Range<Int>?) async throws -> TranscriptionResult

    /// 文件转录：解码 fileURL 指向的音频并转录。
    /// `language` 为可选 ISO-639-1 代码；nil/空 = 自动检测。
    /// `translate` 为 true 时翻译为英文（仅 whisper 引擎支持，其余引擎由
    /// 上层 TranscriptionService 在委托前拒绝）。
    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult

    /// 当前状态快照。
    func status() async -> ASRProviderStatus
}

extension ASRProvider {
    /// 默认实现：无状态引擎不关心绝对位置，直接转发。
    func transcribeChunk(samples: [Float], absoluteRange: Range<Int>?) async throws -> TranscriptionResult {
        try await transcribeChunk(samples: samples)
    }

    /// 默认实现：无状态引擎。
    var isStreamingEngine: Bool { false }
}

// MARK: - 输入补零桶化（InputBucketing）
//
// 推理输入长度对齐 0.5s 整数倍桶：GPU 推理对随机输入形状会触发
// kernel 重选与显存池扩张（周期性延迟毛刺）；桶化后形状集合有限，
// 长时运行复用已调优执行路径。代价：平均每段多算 ~0.25s 尾部静音
//（补在语音之后的尾部零，不诱发幻觉）。仅无状态引擎的 chunk 路径；
// 流式引擎禁用（补零破坏流语义）；文件转录一次性推理无需。

enum InputBucketing {
    /// 0.5s @16kHz。
    static let quantumSamples = 8000

    static func padded(_ samples: [Float]) -> [Float] {
        let remainder = samples.count % quantumSamples
        guard remainder != 0 else { return samples }
        return samples + [Float](repeating: 0, count: quantumSamples - remainder)
    }
}

// MARK: - 流式引擎喂音水位线（StreamingFeedWaterline）
//
// 绝对采样坐标（AudioRecorder.accumulatedSampleCount 坐标系）上的
// 去重水位线：ASRManager 的 tail 重转录每轮重发未封口区间，
// 流式引擎只应收到水位线之后的新增采样。纯逻辑（可单测），
// 由 TranscriptionService 持有——provider 不感知调用方语义。

struct StreamingFeedWaterline {
    private(set) var fedUntil: Int? = nil

    mutating func reset() { fedUntil = nil }

    /// 计算应喂入的起始下标（相对区间内 samples）。
    /// 返回 nil = 区间已全部喂过（本次无需喂入）。
    /// 无区间信息时调用方应走 markUntrackedFeed（保守全量喂）。
    mutating func unfedStart(in range: Range<Int>) -> Int? {
        let fed = fedUntil ?? range.lowerBound
        let from = max(range.lowerBound, fed)
        fedUntil = max(fed, range.upperBound)
        return from < range.upperBound ? (from - range.lowerBound) : nil
    }

    /// 调用方无法提供区间（理论路径）：保守全量喂并清空水位线
    ///（宁可一次性重喂也不能永久漏掉新音频）。
    mutating func markUntrackedFeed() { fedUntil = nil }
}
