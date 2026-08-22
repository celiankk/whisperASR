import Foundation

/// OnlineASRProvider：在线 OpenAI 兼容 Whisper API 适配层。
///
/// 实现 ASRProvider 协议（与本地引擎完全兼容的输入输出）：
/// - 音频分片：由上层 ChunkManager 按「音频分片模式」统一调度
///   （本 Provider 不自行聚合，每次 transcribeChunk 即一次请求）；
/// - 请求管理：ASRRequestQueue（新音频优先、取消旧请求、防重复发送）；
/// - 网络细节：全部委托 OnlineASRService（HTTP / 认证 / 上传 / 解析 / 错误）；
/// - 状态统计：OnlineASRStats（系统状态页展示）。
///
/// 失败语义：任何错误都抛给上层 catch（App 不崩溃、本地 ASR 不受影响），
/// 统计状态置 Error，显示 "Online ASR unavailable"。
final class OnlineASRProvider: @unchecked Sendable, ASRProvider {
    private let service = OnlineASRService()
    private let requestQueue = ASRRequestQueue()
    private let stats = OnlineASRStats.shared
    /// 在线句子模式：音频缓冲（累计达标/停顿才发送，不发送碎片短音频）。
    private let audioBuffer = OnlineASRBuffer()
    /// 在线结果合并（碎片 → 完整句）。
    private let resultAccumulator = OnlineResultAccumulator()

    var engine: ASRProviderEngine { .online }

    // MARK: - ASRProvider

    /// 预加载（在线模式 = 校验配置）。未配置时抛错，由上层提示用户。
    func prepare() async throws {
        try validateConfiguration()
    }

    /// 显式加载（在线模式无本地模型，等价于校验配置）。
    func loadModel() async throws {
        try validateConfiguration()
    }

    /// 释放资源：取消在途请求。
    func unloadModel() async {
        await requestQueue.cancelPending()
        stats.setState(.ready, detail: "已停止")
    }

    /// 实时分块转录：句子模式（sentence mode）——
    /// 音频经 OnlineASRBuffer 累计（目标 ~2.5s / 停顿提前 / 上限兜底），
    /// 达标才发送 API；结果经 OnlineResultAccumulator 合并至句完成。
    /// 未达标返回空（AppState 继续累积，不发送碎片短音频）。
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }
        // 1. 缓冲累积（不直接发送实时 chunk）。
        audioBuffer.append(samples)
        // 2. 达标判定：目标时长 / 末尾停顿 / 上限。
        guard audioBuffer.shouldSend() else {
            return TranscriptionResult(text: "", segments: [])
        }
        let chunk = audioBuffer.takeAll()

        // 3. 发送日志：确认实际发送的音频长度。
        let duration = Double(chunk.count) / 16000.0
        print(String(format: "[Online ASR] audio duration: %.1fs samples: %d chunk: %d",
                     duration, chunk.count, chunk.count))

        // 4. 发送。
        let prompt = ASRPromptManager.shared.currentPrompt
        let start = Date()
        stats.requestStarted()
        do {
            let result = try await requestQueue.submit { [service] in
                // 实时识别语言：设置页「识别语言」（nil = 自动；MiMo 内部
                // 会把不支持的语种映射回 auto）。
                try await service.transcribe(samples: chunk,
                                             language: ConfigurationManager.shared.asr.effectiveASRLanguage,
                                             prompt: prompt) { _ in }
            }
            stats.requestSucceeded(responseTime: Date().timeIntervalSince(start))
            print("[Online ASR] response: \(result.text.debugDescription)")

            // 5. 结果合并：碎片累积，句末标点提交完整句。
            let merged = resultAccumulator.merge(result.text)
            let asr = ASRResult(
                text: merged.text,
                isFinal: merged.isComplete,
                language: result.detectedLanguage,
                confidence: nil,
                timestamp: (0, duration)
            )
            asr.log(provider: "online")
            return asr.toTranscriptionResult()
        } catch {
            stats.requestFailed(error.localizedDescription)
            throw error
        }
    }

    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        try validateConfiguration()
        let prompt = ASRPromptManager.shared.currentPrompt
        let start = Date()
        stats.requestStarted()
        do {
            let effectiveLanguage = (language?.isEmpty == false)
                ? language
                : ConfigurationManager.shared.asr.effectiveASRLanguage
            let result = try await service.transcribe(fileURL: fileURL,
                                                      language: effectiveLanguage,
                                                      prompt: prompt,
                                                      onProgress: onProgress)
            stats.requestSucceeded(responseTime: Date().timeIntervalSince(start))
            // 统一 ASRResult：非流式响应天然 final。
            let asr = Self.makeASRResult(from: result)
            asr.log(provider: "online")
            return asr.toTranscriptionResult()
        } catch {
            stats.requestFailed(error.localizedDescription)
            throw error
        }
    }

    /// TranscriptionResult → 统一 ASRResult（isFinal=true，纯文本时间戳回落）。
    static func makeASRResult(from result: TranscriptionResult) -> ASRResult {
        let first = result.segments.first
        return ASRResult(
            text: result.text,
            isFinal: true,
            language: result.detectedLanguage,
            confidence: nil,
            timestamp: (first?.start ?? 0, first?.end)
        )
    }

    func status() async -> ASRProviderStatus {
        guard OnlineASRConfig.isConfigured else { return .idle }
        return .loaded(path: "Online API（\(OnlineASRConfig.baseURL)）")
    }

    /// 连接测试（设置页「测试连接」按钮）。
    func testConnection() async -> (success: Bool, message: String) {
        await OnlineASRService.testConnection()
    }

    /// 取消在途请求并清空缓冲/累积（结束实时会话时调用，同步版）。
    func cancelPending() {
        audioBuffer.clear()
        resultAccumulator.clear()
        Task { await requestQueue.cancelPending() }
    }

    // MARK: - 私有

    private func validateConfiguration() throws {
        guard OnlineASRConfig.isConfigured else {
            stats.setState(.error, detail: OnlineASRError.notConfigured.errorDescription ?? "未配置")
            throw OnlineASRError.notConfigured
        }
        stats.setState(.ready, detail: "就绪（\(OnlineASRConfig.baseURL)）")
    }
}
