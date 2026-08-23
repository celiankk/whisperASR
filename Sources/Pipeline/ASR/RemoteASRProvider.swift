import Foundation

/// RemoteASRProvider：远程自托管 ASR 端点适配层（LiveTranslate
/// Remote Whisper 对标）。识别卸载到局域网/远程 GPU 机器，本机零模型。
///
/// 与 OnlineASRProvider 同构（句子缓冲 + 请求队列 + 结果合并），差异仅在：
/// - engine = .remote；
/// - 激活时把 OnlineASRConfig 活动源切到 RemoteASRConfig（请求栈复用，
///   见 OnlineASRConfig.isActiveSourceRemote）；
/// - OpenAI Compatible 协议（无 MiMo 分支），密钥可选。
///
/// 失败语义与在线一致：错误抛给上层 catch，本地引擎不受影响。
final class RemoteASRProvider: @unchecked Sendable, ASRProvider {
    private let service = OnlineASRService()
    private let requestQueue = ASRRequestQueue()
    /// 句子模式音频缓冲（累计达标/停顿才发送）。
    private let audioBuffer = OnlineASRBuffer()
    /// 结果合并（碎片 → 完整句）。
    private let resultAccumulator = OnlineResultAccumulator()

    var engine: ASRProviderEngine { .remote }

    // MARK: - ASRProvider

    func prepare() async throws {
        try validateConfiguration()
    }

    func loadModel() async throws {
        try validateConfiguration()
    }

    func unloadModel() async {
        await requestQueue.cancelPending()
        RemoteASRConfig.activateAsActiveSource(false)
    }

    /// 实时分块转录：句子缓冲达标后发送（与在线同策略——远程端点
    /// 每次请求有网络往返，碎片短音频浪费往返且服务端并发受限）。
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }
        audioBuffer.append(samples)
        guard audioBuffer.shouldSend() else {
            return TranscriptionResult(text: "", segments: [])
        }
        let chunk = audioBuffer.takeAll()

        RemoteASRConfig.activateAsActiveSource(true)
        defer { RemoteASRConfig.activateAsActiveSource(false) }

        let prompt = ASRPromptManager.shared.currentPrompt
        do {
            let result = try await requestQueue.submit { [service] in
                // 实时识别语言：设置页「识别语言」（nil = 自动）。
                try await service.transcribe(
                    samples: chunk,
                    language: ConfigurationManager.shared.asr.effectiveASRLanguage,
                    prompt: prompt) { _ in }
            }
            let merged = resultAccumulator.merge(result.text)
            return TranscriptionResult(
                text: merged.text,
                segments: merged.text.isEmpty
                    ? []
                    : [TranscriptionSegment(start: 0, end: Double(chunk.count) / 16000.0,
                                            text: merged.text)],
                detectedLanguage: result.detectedLanguage)
        } catch {
            throw error
        }
    }

    /// 文件转录：整文件上传（WAV 编码在 service 内；25MB 上限由
    /// OnlineASRService.maxUploadBytes 把关，超限抛错提示用户换本地引擎）。
    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        try validateConfiguration()
        RemoteASRConfig.activateAsActiveSource(true)
        defer { RemoteASRConfig.activateAsActiveSource(false) }
        let prompt = ASRPromptManager.shared.currentPrompt
        let effectiveLanguage = (language?.isEmpty == false)
            ? language
            : ConfigurationManager.shared.asr.effectiveASRLanguage
        return try await service.transcribe(fileURL: fileURL,
                                            language: effectiveLanguage,
                                            prompt: prompt,
                                            onProgress: onProgress)
    }

    func status() async -> ASRProviderStatus {
        guard RemoteASRConfig.isConfigured else { return .idle }
        return .loaded(path: "Remote ASR（\(RemoteASRConfig.baseURL)）")
    }

    private func validateConfiguration() throws {
        guard RemoteASRConfig.isEnabled else {
            throw TranscriptionError.processFailed("远程识别未启用（设置 → 识别 → 远程 ASR）")
        }
        guard !RemoteASRConfig.baseURL.isEmpty else {
            throw TranscriptionError.processFailed("远程识别端点未配置")
        }
    }
}
