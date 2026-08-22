import Foundation

// MARK: - FunASR Provider（FunASRProvider）
//
// FunASR 模型（SenseVoice / Paraformer 系）的 ASRProvider 实现——
// 只是新的 Provider，不是独立 ASR 系统：
//
//   ASRManager → TranscriptionService → ASRProvider → FunASRProvider → FunASRRuntime
//
// 音频链路不变：ScreenCaptureKit/Mic → AudioRecorder → VAD → 本 Provider。
// 不自行管理录音；streaming chunk 逻辑沿用 ASRManager 既有循环
//（paraformer-streaming 声明 isStreamingEngine=true 走水位线去重）。

final class FunASRProvider: @unchecked Sendable, ASRProvider {
    let engine: ASRProviderEngine = .funasr

    /// 当前模型类型：按已解析模型路径从 catalog 元数据推导
    /// （catalog 选 paraformer-zh → .paraformerZH；未知回落 SenseVoice）。
    private(set) var modelType: FunASRModelType {
        get { stateLock.withLock { modelTypeStorage } }
        set { stateLock.withLock { modelTypeStorage = newValue } }
    }
    private var modelTypeStorage: FunASRModelType = .senseVoiceSmall

    /// 推理运行时：经注册中心取（sherpa-onnx 后端注册前为占位）。
    private var runtime: FunASRRuntime { FunASRRuntimeRegistry.current() }
    private var loadedPath: String?
    /// 加载互斥：防止实时循环与文件转录并发触发双加载
    /// （检查-加载非原子；load 完成前其他调用等待同一路径）。
    private var inflightLoad: (path: String, task: Task<Void, Never>)?
    private let stateLock = NSLock()

    /// 流式语义：仅 paraformer-streaming 是流式模型（增量喂音 +
    /// 水位线去重）；SenseVoice / Paraformer-zh / Nano 是整段推理，
    /// 但同样不持有跨块状态——按无状态处理（每轮全量重转录安全）。
    var isStreamingEngine: Bool { modelType.isStreaming }

    // MARK: - 生命周期

    func prepare() async throws {
        try await loadModelIfNeeded(directory: liveModelDirectory())
    }

    func loadModel() async throws {
        try await loadModelIfNeeded(directory: modelDirectory())
    }

    func unloadModel() async {
        await runtime.unload()
        stateLock.withLock {
            loadedPath = nil
        }
    }

    // MARK: - 实时分块

    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        try await loadModelIfNeeded(directory: liveModelDirectory())
        let result = try await runtime.infer(pcm: samples)
        return result.toTranscriptionResult()
    }

    // MARK: - 文件转录

    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        guard !translate else {
            throw TranscriptionError.processFailed(
                "Translation to English is not supported by FunASR. Select a Whisper model instead.")
        }
        let samples = try await AudioLoader.loadSamples(url: fileURL)
        try await loadModelIfNeeded(directory: modelDirectory())
        onProgress(0.3)
        let result = try await runtime.infer(pcm: samples)
        onProgress(1)
        return result.toTranscriptionResult()
    }

    func status() async -> ASRProviderStatus {
        if stateLock.withLock({ loadedPath != nil }) {
            return .loaded(path: "FunASR（\(modelType.displayName)）")
        }
        return .idle
    }

    // MARK: - 私有

    private func modelDirectory() -> URL {
        URL(fileURLWithPath: ModelPathResolver.resolveModelPath(), isDirectory: true)
    }

    private func liveModelDirectory() -> URL {
        URL(fileURLWithPath: ModelPathResolver.resolveLiveModelPath(), isDirectory: true)
    }

    /// 按需加载（并发安全）：同路径已有在途加载则等待复用；
    /// 路径变化（主/实时模型切换）先卸载旧模型再加载。
    /// 注意 path 是**单 .onnx 文件路径**（ModelCatalog fileName），
    /// 非 isDirectory——sherpa-onnx load(modelPath:) 直接接受模型文件，
    /// tokens 等附属文件按约定放在同目录由后端解析。
    private func loadModelIfNeeded(directory: URL) async throws {
        let reuseTask: Task<Void, Never>?
        var needsNewLoad = false
        stateLock.lock()
        if loadedPath == directory.path, inflightLoad == nil {
            stateLock.unlock()
            return
        }
        if let inflight = inflightLoad, inflight.path == directory.path {
            reuseTask = inflight.task
            needsNewLoad = false
        } else {
            needsNewLoad = true
            reuseTask = nil
        }
        stateLock.unlock()

        if !needsNewLoad, let reuseTask {
            await reuseTask.value
            return
        }

        // 路径变化：卸载旧实例并推导新模型类型。
        await runtime.unload()
        modelType = Self.modelType(for: directory)

        // 占位 runtime 的 load 会抛错——抛错时清掉 in-flight 记录，
        // 让下次重试；成功则记录 loadedPath。
        let task = Task<Void, Never> {
            do {
                try await self.runtime.load(modelPath: directory, modelType: modelType)
                self.stateLock.withLock { self.loadedPath = directory.path }
            } catch {
                self.stateLock.withLock { self.inflightLoad = nil }
            }
        }
        stateLock.withLock { inflightLoad = (directory.path, task) }
        await task.value
    }

    /// 模型路径 → 类型（按 catalog displayName/id 匹配；未登记回落 SenseVoice）。
    static func modelType(for modelURL: URL) -> FunASRModelType {
        switch modelURL.lastPathComponent {
        case "paraformer-zh-streaming.onnx": return .paraformerStreaming
        case "paraformer-zh.onnx": return .paraformerZH
        case "fun-asr-nano.onnx": return .funASRNano
        default: return .senseVoiceSmall
        }
    }
}
