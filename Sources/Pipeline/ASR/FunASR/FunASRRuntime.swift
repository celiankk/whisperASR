import Foundation

// MARK: - FunASR 运行时抽象（FunASRRuntime）
//
// FunASR 模型推理的统一接口（规格版）：
// - isAvailable：后端可用性（xcframework 未链接/初始化失败 = false）
// - load(modelURL:)：加载模型目录（文件清单见 FunASRModelConfig）
// - transcribe(pcm:sampleRate:)：16kHz mono Float32 → 统一 ASRResult
// - unload()：释放
//
// 后端链路（Commit 2 接入）：Swift → sherpa-onnx C API → ONNX Runtime。
// 后端实现经 FunASRRuntimeRegistry 注册，对 Provider 透明。

/// FunASR 支持的模型类型。
enum FunASRModelType: String, CaseIterable {
    /// SenseVoice-Small：中英日韩粤，低延迟，实时字幕默认推荐。
    case senseVoiceSmall
    /// Paraformer-zh-streaming：中文流式识别（配合既有 streaming chunk 链路）。
    case paraformerStreaming
    /// Paraformer-zh：中文离线高准确率（文件导入/会议转录，支持时间戳）。
    case paraformerZH
    /// Fun-ASR-Nano：LLM-based 多语言（Phase 3，需 sherpa-onnx 最新版）。
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
    /// 后端可用性（xcframework 未链接/初始化失败 = false）。
    var isAvailable: Bool { get }

    /// 加载模型目录（内含 onnx 权重 + tokens；具体文件由
    /// FunASRModelConfig 按模型类型给出）。
    func load(modelURL: URL) async throws

    /// 16kHz mono Float32 PCM → 识别结果（时间戳相对音频起点）。
    /// 实时链路固定 16kHz（AudioRecorder 输出），sampleRate 供后端校验。
    /// 零拷贝切片输入（P0 链路禁 Array(...)）。
    func transcribe(pcm: ArraySlice<Float>, sampleRate: Int) async throws -> ASRResult

    func unload() async
}

/// Runtime 后端注册中心（Commit 2 接入点）：
/// sherpa-onnx 后端实现 FunASRRuntime 后调用
/// `FunASRRuntimeRegistry.register(SherpaONNXRuntime())` 即全链路生效
/// ——Provider 经此取运行时，占位/真实后端对 Provider 透明。
enum FunASRRuntimeRegistry {
    private static let lock = NSLock()
    private static var backend: FunASRRuntime = PlaceholderFunASRRuntime()

    /// 注册真实后端（应用启动或后端模块加载时调用一次）。
    ///
    /// 幂等：已在库中的实例原样保留。`FunASRProvider.runtime` 是**每次调用
    /// 都查注册中心**的计算属性，若此处用新实例覆盖，已加载模型的旧实例
    /// 会被丢弃 —— 表现为加载成功但紧接着 transcribe 报
    /// "FunASR runtime unavailable"（实测：窗口 onAppear 与评测入口各自
    /// 注册一次，两次注册之间恰好加载完模型时必现，约 1/6 概率）。
    static func register(_ runtime: FunASRRuntime) {
        lock.withLock {
            guard backend is PlaceholderFunASRRuntime else { return }
            backend = runtime
        }
    }

    static func current() -> FunASRRuntime {
        lock.withLock { backend }
    }
}

/// 占位运行时：xcframework 桥接接入前保持 runtime unavailable 状态
/// （明确报错，不静默失败；Provider 全链路已可编译、可选择、可下载）。
struct PlaceholderFunASRRuntime: FunASRRuntime {
    var isAvailable: Bool { false }

    func load(modelURL: URL) async throws {
        throw TranscriptionError.processFailed("FunASR runtime unavailable")
    }

    func transcribe(pcm: ArraySlice<Float>, sampleRate: Int) async throws -> ASRResult {
        throw TranscriptionError.processFailed("FunASR runtime unavailable")
    }

    func unload() async {}
}
