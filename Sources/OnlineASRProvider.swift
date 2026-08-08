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

    /// 实时分块转录：直接上传（分片聚合由上层 ChunkManager 完成，
    /// 收到即达标的完整切片）。
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }

        let start = Date()
        stats.requestStarted()
        do {
            let result = try await requestQueue.submit { [service] in
                try await service.transcribe(samples: samples, language: nil) { _ in }
            }
            stats.requestSucceeded(responseTime: Date().timeIntervalSince(start))
            return result
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
        let start = Date()
        stats.requestStarted()
        do {
            let result = try await service.transcribe(fileURL: fileURL,
                                                      language: language,
                                                      onProgress: onProgress)
            stats.requestSucceeded(responseTime: Date().timeIntervalSince(start))
            return result
        } catch {
            stats.requestFailed(error.localizedDescription)
            throw error
        }
    }

    func status() async -> ASRProviderStatus {
        guard OnlineASRConfig.isConfigured else { return .idle }
        return .loaded(path: "Online API（\(OnlineASRConfig.baseURL)）")
    }

    /// 连接测试（设置页「测试连接」按钮）。
    func testConnection() async -> (success: Bool, message: String) {
        await OnlineASRService.testConnection()
    }

    /// 取消在途请求（结束实时会话时调用，同步版）。
    func cancelPending() {
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
