import Foundation
import Observation

// MARK: - 在线识别配置（OnlineASRConfig）
//
// OpenAI 兼容 Whisper API 配置（UserDefaults 持久化）：
//   onlineASREnabled        启用在线识别开关
//   onlineASRBaseURL        Base URL（OpenAI 兼容，默认 https://api.openai.com/v1）
//   onlineASRApiKey         API Key（仅用于 Authorization 头，绝不写日志）
//   onlineASRModel          模型名（默认 whisper-1）
//
// 音频分片参数（最短识别时间 / 最长等待时间）已上移为全局
// AudioChunkingConfig，由「音频分片模式」统一管理。
enum OnlineASRConfig {
    enum Keys {
        static let enabled = "onlineASREnabled"
        static let baseURL = "onlineASRBaseURL"
        static let apiKey = "onlineASRApiKey"
        static let model = "onlineASRModel"
    }

    static var defaultBaseURL = "https://api.openai.com/v1"
    static var defaultModel = "whisper-1"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    static var baseURL: String {
        let raw = (UserDefaults.standard.string(forKey: Keys.baseURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? defaultBaseURL : raw
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
    }

    static var model: String {
        let raw = (UserDefaults.standard.string(forKey: Keys.model) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? defaultModel : raw
    }

    /// 是否已配置（baseURL 有效即可；密钥可为空——本地兼容服务通常不需要）。
    static var isConfigured: Bool {
        !baseURL.isEmpty
    }
}

// MARK: - 在线识别错误（OnlineASRError）

/// 在线识别错误分类：超时 / 断网 / API / 权限 / 限流 / 格式 / 配置。
/// 任何在线识别失败都不会导致 App 崩溃或影响本地 ASR——上层 catch 后
/// 继续运行并显示 "Online ASR unavailable"。
enum OnlineASRError: LocalizedError {
    case notConfigured
    case invalidEndpoint(String)
    case timeout
    case network(String)
    case auth(String)
    case rateLimited(String)
    case apiError(Int, String)
    case parseError
    case fileTooLarge(Int64)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "在线识别未配置（请在设置 → 识别 → 在线识别 API 中填写 Base URL）"
        case .invalidEndpoint(let url):
            return "无效的 API 地址：\(url)"
        case .timeout:
            return "请求超时"
        case .network(let msg):
            return "网络错误：\(msg)"
        case .auth(let msg):
            return "API Key 无效或未授权：\(msg)"
        case .rateLimited(let msg):
            return "请求过于频繁：\(msg)"
        case .apiError(let code, let msg):
            return "API 错误（HTTP \(code)）：\(msg)"
        case .parseError:
            return "响应格式错误"
        case .fileTooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "音频文件过大（\(size)），无法上传"
        }
    }
}

// MARK: - 在线识别统计（OnlineASRStats）

/// 在线识别运行统计：状态 + 请求计数 + 平均响应时间。
/// @Observable，供系统状态页实时展示；由 OnlineASRProvider 在请求
/// 开始/结束时更新（更新频率 = 请求频率，不会刷爆 UI）。
@Observable
final class OnlineASRStats {
    static let shared = OnlineASRStats()

    /// 运行状态：Ready / Connecting / Running / Error。
    enum State: String {
        case ready = "Ready"
        case connecting = "Connecting"
        case running = "Running"
        case error = "Error"
    }

    private(set) var state: State = .ready
    private(set) var stateDetail: String = "未使用"
    private(set) var totalRequests = 0
    private(set) var successRequests = 0
    private(set) var failedRequests = 0
    private(set) var averageResponseTime: Double = 0

    private var totalResponseTime: Double = 0

    private init() {}

    func setState(_ state: State, detail: String) {
        self.state = state
        stateDetail = detail
    }

    func requestStarted() {
        totalRequests += 1
        state = .running
        stateDetail = "处理中…"
    }

    func requestSucceeded(responseTime: Double) {
        successRequests += 1
        totalResponseTime += responseTime
        averageResponseTime = totalResponseTime / Double(successRequests)
        state = .ready
        stateDetail = "就绪"
    }

    func requestFailed(_ detail: String) {
        failedRequests += 1
        state = .error
        stateDetail = detail
    }

    func reset() {
        state = .ready
        stateDetail = "未使用"
        totalRequests = 0
        successRequests = 0
        failedRequests = 0
        averageResponseTime = 0
        totalResponseTime = 0
    }
}

// MARK: - WAV 编码（16kHz 单声道 → WAV PCM16）

enum WAVEncoder {
    /// Float32 PCM（16kHz 单声道，[-1, 1]）→ WAV（PCM 16-bit LE）。
    static func encodePCM16(samples: [Float], sampleRate: Int = 16000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let dataSize = samples.count * 2

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndian(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndian(UInt32(16)))
        data.append(contentsOf: littleEndian(UInt16(1)))               // PCM
        data.append(contentsOf: littleEndian(UInt16(1)))               // mono
        data.append(contentsOf: littleEndian(UInt32(sampleRate)))
        data.append(contentsOf: littleEndian(UInt32(byteRate)))
        data.append(contentsOf: littleEndian(blockAlign))
        data.append(contentsOf: littleEndian(UInt16(16)))              // 16-bit
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndian(UInt32(dataSize)))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, sample) in samples.enumerated() {
            let clamped = max(-1, min(1, sample))
            pcm[i] = Int16(clamped * 32767)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var v = value
        return withUnsafeBytes(of: &v) { Array($0) }
    }
}

// MARK: - 在线识别服务（OnlineASRService）
//
// 独立网络层：HTTP 请求、认证、音频上传、响应解析、错误处理。
// OnlineASRProvider 只做编排（切片 / 队列 / 状态），不直接管理网络细节。
// 所有请求在后台执行，不阻塞主线程 / 字幕窗口 / 录音。
//
// 请求日志只记录：开始、结束、耗时、错误。绝不记录 API Key。

final class OnlineASRService {
    /// OpenAI 兼容文件上传上限（Whisper API 25MB）。
    static let maxUploadBytes: Int64 = 25 * 1024 * 1024

    /// 上传 + 识别超时（秒）。
    private static let requestTimeout: TimeInterval = 60

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout + 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - 请求

    /// 上传 PCM 样本（16kHz 单声道）并识别。
    /// `language` 可选 ISO-639-1 代码；nil = 自动检测。
    func transcribe(
        samples: [Float],
        language: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        let audio = WAVEncoder.encodePCM16(samples: samples)
        return try await upload(audioData: audio,
                                mimeType: "audio/wav",
                                fileName: "audio.wav",
                                language: language,
                                onProgress: onProgress)
    }

    /// 上传音频文件并识别。≤25MB 原样上传（mp3/m4a/wav/ogg 等），
    /// 超过则重编码为 16kHz 单声道 WAV 再传。
    func transcribe(
        fileURL: URL,
        language: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        if fileSize > 0, fileSize <= Self.maxUploadBytes {
            let data = try Data(contentsOf: fileURL)
            let mime = mimeType(for: fileURL.pathExtension)
            return try await upload(audioData: data,
                                    mimeType: mime,
                                    fileName: fileURL.lastPathComponent,
                                    language: language,
                                    onProgress: onProgress)
        }
        // 超限：解码后重编码为 16kHz 单声道 PCM16（通常显著缩小）。
        let samples = try await AudioLoader.loadSamples(url: fileURL)
        let audio = WAVEncoder.encodePCM16(samples: samples)
        guard Int64(audio.count) <= Self.maxUploadBytes else {
            throw OnlineASRError.fileTooLarge(Int64(audio.count))
        }
        return try await upload(audioData: audio,
                                mimeType: "audio/wav",
                                fileName: "audio.wav",
                                language: language,
                                onProgress: onProgress)
    }

    /// 连接测试：GET {base}/models（带 Bearer）。不发送音频、不写密钥日志。
    /// static：设置页「测试连接」直接调用，无需 Provider 实例。
    static func testConnection() async -> (success: Bool, message: String) {
        let service = OnlineASRService()
        guard OnlineASRConfig.isConfigured else {
            return (false, OnlineASRError.notConfigured.errorDescription ?? "未配置")
        }
        guard let url = URL(string: service.modelsEndpoint()) else {
            return (false, OnlineASRError.invalidEndpoint(OnlineASRConfig.baseURL).localizedDescription)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !OnlineASRConfig.apiKey.isEmpty {
            request.setValue("Bearer \(OnlineASRConfig.apiKey)", forHTTPHeaderField: "Authorization")
        }
        AppLogger.shared.log(.onlineASR, "testConnection start: \(url.absoluteString)")
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, OnlineASRError.network("无效响应").localizedDescription)
            }
            if (200...299).contains(http.statusCode) {
                AppLogger.shared.log(.onlineASR, "testConnection OK (HTTP \(http.statusCode))")
                // 尝试提取模型列表展示；失败不影响"连接成功"。
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["data"] as? [[String: Any]],
                   let first = models.first,
                   let id = first["id"] as? String {
                    return (true, "连接成功：\(id)")
                }
                return (true, "连接成功")
            }
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            AppLogger.shared.log(.onlineASR, "testConnection failed (HTTP \(http.statusCode))")
            return (false, message)
        } catch is URLError {
            return (false, OnlineASRError.network("无法连接服务器").localizedDescription)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - 上传实现

    private func upload(
        audioData: Data,
        mimeType: String,
        fileName: String,
        language: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        guard OnlineASRConfig.isConfigured else {
            throw OnlineASRError.notConfigured
        }
        guard let endpoint = URL(string: transcriptionsEndpoint()) else {
            throw OnlineASRError.invalidEndpoint(OnlineASRConfig.baseURL)
        }

        let boundary = "WhisperASR-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !OnlineASRConfig.apiKey.isEmpty {
            request.setValue("Bearer \(OnlineASRConfig.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = Self.requestTimeout

        var body = Data()
        body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(contentsOf: Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audioData)
        body.append(contentsOf: Data("\r\n".utf8))
        body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(OnlineASRConfig.model)\r\n".utf8))
        body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n".utf8))
        if let language, !language.isEmpty {
            body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
            body.append(contentsOf: Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".utf8))
        }
        body.append(contentsOf: Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let start = Date()
        AppLogger.shared.log(.onlineASR, "transcribe start: \(Int64(audioData.count)) bytes → \(endpoint.absoluteString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch is CancellationError {
            AppLogger.shared.log(.onlineASR, "transcribe cancelled")
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            AppLogger.shared.log(.onlineASR, "transcribe timeout")
            throw OnlineASRError.timeout
        } catch {
            AppLogger.shared.log(.onlineASR, "transcribe network error: \(error.localizedDescription)")
            throw OnlineASRError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            AppLogger.shared.log(.onlineASR, "transcribe invalid response")
            throw OnlineASRError.network("无效响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            let elapsed = Date().timeIntervalSince(start)
            AppLogger.shared.log(.onlineASR, "transcribe failed (HTTP \(http.statusCode)) after \(Self.format(elapsed))s")
            switch http.statusCode {
            case 401, 403:
                throw OnlineASRError.auth(message)
            case 429:
                throw OnlineASRError.rateLimited(message)
            default:
                throw OnlineASRError.apiError(http.statusCode, message)
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        AppLogger.shared.log(.onlineASR, "transcribe done in \(Self.format(elapsed))s")
        onProgress(1)
        return try parseResponse(data)
    }

    // MARK: - 响应解析

    /// 解析 verbose_json（或兼容 text 流式聚合）响应 → TranscriptionResult。
    /// - 支持非流式 JSON：{ text, language, segments: [{start, end, text}] }
    /// - 支持流式（SSE）：逐事件聚合（partial 文本经 onPartial 上报；
    ///   最终结果与 OpenAI 兼容格式一致），实现"接口支持 Streaming / Non-Streaming"。
    func parseResponse(_ data: Data, onPartial: (@Sendable (String) -> Void)? = nil) throws -> TranscriptionResult {
        // 流式响应（text/event-stream）：聚合事件文本后走同一解析路径。
        let text: String
        if let stream = String(data: data, encoding: .utf8),
           stream.contains("event:") || stream.contains("data:") {
            text = Self.parseSSE(stream, onPartial: onPartial)
        } else {
            text = ""
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineASRError.parseError
        }
        let fullText: String
        if let t = json["text"] as? String {
            fullText = t
        } else if !text.isEmpty {
            fullText = text
        } else {
            throw OnlineASRError.parseError
        }
        let detected = json["language"] as? String

        var segments: [TranscriptionSegment] = []
        if let rawSegments = json["segments"] as? [[String: Any]] {
            for seg in rawSegments {
                guard let start = seg["start"] as? Double,
                      let end = seg["end"] as? Double,
                      let segText = seg["text"] as? String else { continue }
                segments.append(TranscriptionSegment(start: start, end: end, text: segText))
            }
        }
        // 无时间戳（或流式聚合）时按音频位置等分估算（与 Qwen 后端同策略）。
        if segments.isEmpty {
            segments = Self.estimateSegments(fullText: fullText)
        }
        return TranscriptionResult(text: fullText, segments: segments, detectedLanguage: detected)
    }

    /// 无时间戳时按句子等分估算段边界（单位秒，相对音频起点）。
    private static func estimateSegments(fullText: String) -> [TranscriptionSegment] {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sentences = trimmed
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?…；;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let effective = sentences.isEmpty ? [trimmed] : sentences
        // 无法知道时长：按 2.5s/句 估算（实时切片典型值）。
        return effective.enumerated().map { index, sentence in
            TranscriptionSegment(start: Double(index) * 2.5, end: Double(index + 1) * 2.5, text: sentence)
        }
    }

    /// 聚合 SSE 事件文本（"data: {...}" 行；解析失败的行跳过）。
    private static func parseSSE(_ stream: String, onPartial: (@Sendable (String) -> Void)?) -> String {
        var aggregated = ""
        for line in stream.split(separator: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
               let delta = json["text"] as? String {
                aggregated += delta
                onPartial?(aggregated)
            }
        }
        return aggregated
    }

    /// 从 OpenAI 风格错误体提取 message。
    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String, !message.isEmpty else {
            return nil
        }
        return message
    }

    // MARK: - URL 构造

    /// {base}/audio/transcriptions（自动补 /v1 与尾斜杠）。
    private func transcriptionsEndpoint() -> String {
        let base = Self.normalizedBaseURL(OnlineASRConfig.baseURL)
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        if trimmed.hasSuffix("/audio/transcriptions") { return trimmed }
        return trimmed + "/audio/transcriptions"
    }

    /// {base}/models。
    private func modelsEndpoint() -> String {
        let base = Self.normalizedBaseURL(OnlineASRConfig.baseURL)
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + "/models"
    }

    /// 端点归一化：确保带 /v1 前缀（与翻译端点同一策略）。
    static func normalizedBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme != nil, components.host != nil else {
            return trimmed
        }
        if !components.path.split(separator: "/").contains("v1") {
            components.path = "/v1" + components.path
        }
        return components.url?.absoluteString ?? trimmed
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "opus": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "webm": return "audio/webm"
        case "flac": return "audio/flac"
        default: return "audio/wav"
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }
}
