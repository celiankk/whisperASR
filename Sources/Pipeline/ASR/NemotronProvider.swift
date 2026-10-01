import Foundation

/// NemotronProvider：NVIDIA Nemotron（FluidAudio / Core ML / ANE）适配层。
///
/// 包装 NemotronEngine actor，对外暴露统一 ASRProvider 接口。内部推理逻辑
/// 未改动：模型包目录加载、RNNT token 时序 → TranscriptionSegment 的转换、
/// 语言检测全部保持 1.4 行为。
final class NemotronProvider: @unchecked Sendable, ASRProvider {
    private let nemotron = NemotronEngine()
    /// 最近一次加载的模型目录（status() 报告用；引擎侧加载在 actor 内串行）。
    private let stateLock = NSLock()
    private var loadedDirectory: String?
    /// 最近一次应用到实时引擎的语言（避免每块重复 setLanguage）。
    private var lastLiveLanguage: String?

    var engine: ASRProviderEngine { .nemotron }

    /// 当前转录模型目录（主模型解析规则）。
    private func directoryURL() -> URL {
        URL(fileURLWithPath: ModelPathResolver.resolveModelPath(), isDirectory: true)
    }

    /// 实时转录模型目录（live 选择存在时优先，否则同主模型）。
    private func liveDirectoryURL() -> URL {
        URL(fileURLWithPath: ModelPathResolver.resolveLiveModelPath(), isDirectory: true)
    }

    // MARK: - ASRProvider

    func prepare() async throws {
        let url = liveDirectoryURL()
        try await nemotron.ensureLoaded(directory: url)
        stateLock.withLock { loadedDirectory = url.path }
    }

    func loadModel() async throws {
        let url = directoryURL()
        try await nemotron.ensureLoaded(directory: url)
        stateLock.withLock { loadedDirectory = url.path }
    }

    func unloadModel() async {
        await nemotron.unload()
        stateLock.withLock { loadedDirectory = nil }
    }

    func transcribeChunk(samples: ArraySlice<Float>) async throws -> TranscriptionResult {
        try await nemotron.ensureLoaded(directory: liveDirectoryURL())
        // 实时识别语言：设置页「识别语言」；变化时才重新设置（避免每块
        // 重复调用 setLanguage）。nil = 自动检测。
        let effective = ConfigurationManager.shared.asr.effectiveASRLanguage
        if effective != lastLiveLanguage {
            await nemotron.applyLanguage(effective)
            lastLiveLanguage = effective
        }
        return try await nemotron.transcribeChunk(samples: samples)
    }

    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        let samples = try await AudioLoader.loadSamples(url: fileURL)
        return try await nemotron.transcribe(samples: samples, language: language, onProgress: onProgress)
    }

    func status() async -> ASRProviderStatus {
        if await nemotron.isLoaded, let path = stateLock.withLock({ loadedDirectory }) {
            return .loaded(path: path)
        }
        return .idle
    }
}
