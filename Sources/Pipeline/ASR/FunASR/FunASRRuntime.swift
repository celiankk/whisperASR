import Foundation

// MARK: - FunASR 运行时抽象（FunASRRuntime）
//
// FunASR 模型推理的统一接口（对标规格中的 ASRRuntime 协议）：
// - load(modelPath:)   加载 ONNX 模型（SenseVoice / Paraformer 系）；
// - infer(pcm:)        16kHz mono Float32 推理 → 统一 ASRResult；
// - unload()           释放模型资源。
//
// 后端实现（段 2）：sherpa-onnx Swift API（FunASR 官方导出的 ONNX
// 模型在其生态内推理；macOS 有预编译 xcframework）。
// 当前段 1 提供占位实现（明确的 unavailable 错误），保证：
// - Provider/路由/目录/UI 全链路可编译、可选择、可下载；
// - 选择 FunASR 模型时得到明确错误而非静默失败。

/// FunASR 支持的模型类型。
enum FunASRModelType: String, CaseIterable {
    /// SenseVoice-Small：中英日韩多语，低延迟，实时字幕默认推荐。
    case senseVoiceSmall
    /// Paraformer-zh-streaming：中文流式识别（配合既有 streaming chunk 链路）。
    case paraformerStreaming
    /// Paraformer-zh：中文离线高准确率（文件导入/会议转录）。
    case paraformerZH
    /// Fun-ASR-Nano：高质量多语言大型本地模型选项。
    case funASRNano

    var displayName: String {
        switch self {
        case .senseVoiceSmall: return "SenseVoice-Small"
        case .paraformerStreaming: return "Paraformer-zh-streaming"
        case .paraformerZH: return "Paraformer-zh"
        case .funASRNano: return "Fun-ASR-Nano"
        }
    }

    /// 是否为流式模型（决定 transcribeChunk 语义声明）。
    var isStreaming: Bool {
        self == .paraformerStreaming
    }
}

/// FunASR 推理运行时协议（后端可替换：sherpa-onnx / 未来 Core ML 导出）。
protocol FunASRRuntime: Sendable {
    func load(modelPath: URL) async throws
    /// 16kHz mono Float32 PCM → 识别结果（时间戳相对音频起点）。
    func infer(pcm: [Float], modelType: FunASRModelType) async throws -> ASRResult
    func unload() async
}

/// 占位运行时：sherpa-onnx 后端接入前的明确报错（不静默失败）。
struct PlaceholderFunASRRuntime: FunASRRuntime {
    func load(modelPath: URL) async throws {
        throw TranscriptionError.processFailed(
            "FunASR runtime 尚未接入（sherpa-onnx 后端开发中）；模型已可下载与选择。")
    }

    func infer(pcm: [Float], modelType: FunASRModelType) async throws -> ASRResult {
        throw TranscriptionError.processFailed("FunASR runtime 尚未接入")
    }

    func unload() async {}
}
