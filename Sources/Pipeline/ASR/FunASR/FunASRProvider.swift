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

    /// 当前加载的模型类型（由 TranscriptionService 按模型解析注入）。
    private(set) var modelType: FunASRModelType = .senseVoiceSmall

    /// 推理运行时（sherpa-onnx 后端接入前为占位）。
    private var runtime: FunASRRuntime = PlaceholderFunASRRuntime()
    private var loadedPath: String?
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
        let result = try await runtime.infer(pcm: samples, modelType: modelType)
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
        let result = try await runtime.infer(pcm: samples, modelType: modelType)
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

    private func loadModelIfNeeded(directory: URL) async throws {
        let alreadyLoaded = stateLock.withLock { loadedPath == directory.path }
        guard !alreadyLoaded else { return }
        try await runtime.load(modelPath: directory)
        stateLock.withLock { loadedPath = directory.path }
    }
}
