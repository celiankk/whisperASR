import Foundation

/// QwenProvider：Qwen3-ASR（transcribe.cpp / ggml + Metal）适配层。
///
/// 包装 Qwen3ASRBackend，对外暴露统一 ASRProvider 接口。内部推理逻辑未改动：
/// GGUF 会话加载、全文本输出、按音频位置估算段边界均保持 1.4 行为。
final class QwenProvider: @unchecked Sendable, ASRProvider {
    private let backend = Qwen3ASRBackend()
    /// 最近一次加载的模型路径（status() 报告用；后端加载在自身串行队列内）。
    private let stateLock = NSLock()
    private var loadedModelPath: String?

    var engine: ASRProviderEngine { .qwen3asr }

    /// 当前转录模型路径（主模型解析规则）。
    private func modelURL() -> URL {
        URL(fileURLWithPath: ModelPathResolver.resolveModelPath())
    }

    /// 实时转录模型路径（live 选择存在时优先，否则同主模型）。
    private func liveModelURL() -> URL {
        URL(fileURLWithPath: ModelPathResolver.resolveLiveModelPath())
    }

    // MARK: - ASRProvider

    func prepare() async throws {
        let url = liveModelURL()
        try await backend.ensureLoaded(modelURL: url)
        stateLock.withLock { loadedModelPath = url.path }
    }

    func loadModel() async throws {
        let url = modelURL()
        try await backend.ensureLoaded(modelURL: url)
        stateLock.withLock { loadedModelPath = url.path }
    }

    func unloadModel() async {
        await backend.unload()
        stateLock.withLock { loadedModelPath = nil }
    }

    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        try await backend.ensureLoaded(modelURL: liveModelURL())
        return try await backend.transcribe(samples: samples)
    }

    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        try await backend.ensureLoaded(modelURL: modelURL())
        return try await backend.transcribe(fileURL: fileURL, language: language, onProgress: onProgress)
    }

    func status() async -> ASRProviderStatus {
        if backend.isLoaded, let path = stateLock.withLock({ loadedModelPath }) {
            return .loaded(path: path)
        }
        return .idle
    }
}
