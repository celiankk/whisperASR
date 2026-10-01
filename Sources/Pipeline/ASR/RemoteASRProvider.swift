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
    /// 喂水水位线：与 OnlineASRProvider 同理——上层每轮重发整个未封口
    /// tail，而本 Provider 的句子缓冲跨调用累积，不去重会重复识别同一段
    /// 音频（字幕出现重复词）。
    private var feedWaterline = StreamingFeedWaterline()
    private let waterlineLock = NSLock()

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
        // 清空跨会话累积态：上一段录音末尾不足发送阈值的音频（以及
        // 未到句末的累积文本）若不清理，会作为下一次录音的第一次请求
        // 发出——新录制的第一句字幕混入上次的话。
        audioBuffer.clear()
        resultAccumulator.clear()
        waterlineLock.withLock { feedWaterline.reset() }
        RemoteASRConfig.activateAsActiveSource(false)
    }

    /// 实时分块转录：先按水位线剔除已缓冲过的重复音频，再走句子缓冲
    /// （达标才发送——远程端点每次请求有网络往返，碎片短音频浪费往返）。
    /// 输入零拷贝切片（P0 链路）。
    func transcribeChunk(samples: ArraySlice<Float>,
                         absoluteRange: Range<Int>?) async throws -> TranscriptionResult {
        let newSamples: ArraySlice<Float>
        if let range = absoluteRange {
            let start = waterlineLock.withLock { feedWaterline.unfedStart(in: range) }
            guard let start else {
                // 区间已全部喂过：本轮无新产出，属「聚合中」而非空结果。
                return TranscriptionResult(text: "", segments: [], isAggregationPending: true)
            }
            newSamples = samples.dropFirst(start)
        } else {
            waterlineLock.withLock { feedWaterline.markUntrackedFeed() }
            newSamples = samples
        }
        return try await transcribeChunk(samples: newSamples)
    }

    func transcribeChunk(samples: ArraySlice<Float>) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [], isAggregationPending: true)
        }
        audioBuffer.append(samples)
        guard audioBuffer.shouldSend() else {
            // 未达标 = 音频仍在缓冲累积（远程端点每次请求有网络往返，
            // 碎片短音频不发送）。标记 isAggregationPending，调度层不得
            // 据此清掉屏幕上正在显示的当前句。
            return TranscriptionResult(text: "", segments: [], isAggregationPending: true)
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
