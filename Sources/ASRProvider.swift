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
}

/// Provider 状态快照。
enum ASRProviderStatus: Sendable, Equatable {
    /// 未加载任何模型。
    case idle
    /// 模型已加载，附模型路径。
    case loaded(path: String)
}

/// 统一 ASR Provider 接口。
protocol ASRProvider: Sendable {
    /// 引擎标识。
    var engine: ASRProviderEngine { get }

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
