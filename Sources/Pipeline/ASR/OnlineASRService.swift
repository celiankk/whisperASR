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
        static let streaming = "onlineASRStreaming"
        static let mimoLanguage = "onlineASRMimoLanguage"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    /// 默认值按 API 类型（openai → api.openai.com/v1 + whisper-1；
    /// mimo → api.xiaomimimo.com/v1 + mimo-v2.5-asr）。
    static var defaultBaseURL: String { OnlineASRApiType.current.defaultBaseURL }
    static var defaultModel: String { OnlineASRApiType.current.defaultModel }

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

    /// API 类型（OpenAI Compatible 自动拼路径 / MiMo chat/completions / Custom 原样）。
    static var apiType: OnlineASRApiType {
        OnlineASRApiType.current
    }

    /// 流式输出（仅 MiMo 生效；文档支持 stream=true，逐 chunk 返回）。
    static var streaming: Bool {
        UserDefaults.standard.bool(forKey: Keys.streaming)
    }

    /// MiMo 指定语种（auto / zh / en；文档推荐显式指定提升准确率）。
    static var mimoLanguage: String {
        let raw = (UserDefaults.standard.string(forKey: Keys.mimoLanguage) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ["auto", "zh", "en"].contains(raw) ? raw : "auto"
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
    /// MiMo Base64 上限（文档：Base64 字符串 ≤ 10MB → 原始音频 ≈ 7.5MB）。
    static let maxMimoBytes: Int64 = Int64(10 * 1024 * 1024 * 3 / 4)

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
    /// `prompt` 可选识别提示词（热词/术语，OpenAI Whisper API `prompt` 字段）。
    func transcribe(
        samples: [Float],
        language: String?,
        prompt: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        let audio = WAVEncoder.encodePCM16(samples: samples)
        if OnlineASRConfig.apiType == .mimo {
            // 小米 MiMo：chat/completions + input_audio（Base64）。
            return try await uploadMimo(audioData: audio, language: language, onProgress: onProgress)
        }
        return try await upload(audioData: audio,
                                mimeType: "audio/wav",
                                fileName: "audio.wav",
                                language: language,
                                prompt: prompt,
                                onProgress: onProgress)
    }

    /// 上传音频文件并识别。≤25MB 原样上传（mp3/m4a/wav/ogg 等），
    /// 超过则重编码为 16kHz 单声道 WAV 再传。
    func transcribe(
        fileURL: URL,
        language: String?,
        prompt: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        if OnlineASRConfig.apiType == .mimo {
            // MiMo：仅 wav/mp3，Base64 ≤ 10MB；统一转 16kHz WAV。
            let samples = try await AudioLoader.loadSamples(url: fileURL)
            let audio = WAVEncoder.encodePCM16(samples: samples)
            guard Int64(audio.count) <= Self.maxMimoBytes else {
                throw OnlineASRError.fileTooLarge(Int64(audio.count))
            }
            return try await uploadMimo(audioData: audio, language: language, onProgress: onProgress)
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        if fileSize > 0, fileSize <= Self.maxUploadBytes {
            let data = try Data(contentsOf: fileURL)
            let mime = mimeType(for: fileURL.pathExtension)
            return try await upload(audioData: data,
                                    mimeType: mime,
                                    fileName: fileURL.lastPathComponent,
                                    language: language,
                                    prompt: prompt,
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
                                prompt: prompt,
                                onProgress: onProgress)
    }

    /// 连接测试：发送最小音频（0.5s 静音 WAV）验证端到端连通。
    /// 成功返回模型与响应时间；失败返回 URL/状态码/服务器内容。
    /// static：设置页「测试连接」直接调用，无需 Provider 实例。
    static func testConnection() async -> (success: Bool, message: String) {
        let service = OnlineASRService()
        guard OnlineASRConfig.isConfigured else {
            return (false, OnlineASRError.notConfigured.errorDescription ?? "未配置")
        }
        if OnlineASRConfig.apiType == .mimo {
            // MiMo：走真实 chat/completions 请求验证。
            let silence = [Float](repeating: 0, count: 8000)
            let audio = WAVEncoder.encodePCM16(samples: silence)
            do {
                let start = Date()
                _ = try await service.uploadMimo(audioData: audio, language: nil) { _ in }
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                return (true, "API Connected — 模型：\(OnlineASRConfig.model)，响应：\(elapsedMs)ms")
            } catch {
                return (false, error.localizedDescription)
            }
        }
        guard let url = URL(string: service.transcriptionsEndpoint()) else {
            return (false, OnlineASRError.invalidEndpoint(OnlineASRConfig.baseURL).localizedDescription)
        }

        // 最小音频：0.5s 16kHz 静音（仅验证请求链路，不依赖识别内容）。
        let silence = [Float](repeating: 0, count: 8000)
        let audio = WAVEncoder.encodePCM16(samples: silence)

        let boundary = "WhisperASR-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !OnlineASRConfig.apiKey.isEmpty {
            request.setValue("Bearer \(OnlineASRConfig.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        var body = Data()
        body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".utf8))
        body.append(contentsOf: Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(contentsOf: Data("\r\n".utf8))
        body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(OnlineASRConfig.model)\r\n".utf8))
        body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))
        body.append(contentsOf: Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        AppLogger.shared.log(.onlineASR, "testConnection start: POST \(url.absoluteString)")
        let start = Date()
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, OnlineASRError.network("无效响应").localizedDescription)
            }
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            if (200...299).contains(http.statusCode) {
                let model = OnlineASRConfig.model
                AppLogger.shared.log(.onlineASR, "testConnection OK (HTTP \(http.statusCode)) model=\(model) \(elapsedMs)ms")
                return (true, "API Connected — 模型：\(model)，响应：\(elapsedMs)ms")
            }
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            AppLogger.shared.log(.onlineASR, "testConnection failed (HTTP \(http.statusCode)) body=\(bodyPreview)")
            return (false, "请求：\(url.absoluteString)\n状态码：\(http.statusCode)\n\(message)")
        } catch is URLError {
            return (false, OnlineASRError.network("无法连接服务器：\(url.absoluteString)").localizedDescription)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - 上传实现

    /// 小米 MiMo 转录：POST {base}/chat/completions，messages 内 input_audio
    /// 多模态格式（Base64 data URI），认证头 api-key:，asr_options.language=auto/zh/en。
    /// 文档：https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/audio/Speech-Recognition
    private func uploadMimo(audioData: Data,
                            language: String?,
                            onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        var endpoint = OnlineASRConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        if !endpoint.hasSuffix("/chat/completions") {
            endpoint += "/chat/completions"
        }
        guard let url = URL(string: endpoint) else {
            throw OnlineASRError.invalidEndpoint(OnlineASRConfig.baseURL)
        }

        let dataURI = "data:audio/wav;base64,\(audioData.base64EncodedString())"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // MiMo 认证：api-key header（非 Bearer）。
        if !OnlineASRConfig.apiKey.isEmpty {
            request.setValue(OnlineASRConfig.apiKey, forHTTPHeaderField: "api-key")
        }
        request.timeoutInterval = Self.requestTimeout

        let body: [String: Any] = [
            "model": OnlineASRConfig.model,
            "messages": [
                ["role": "user", "content": [
                    ["type": "input_audio",
                     "input_audio": ["data": dataURI, "format": "wav"]],
                ]],
            ],
            "asr_options": ["language": Self.effectiveMimoLanguage(language)],
            "stream": OnlineASRConfig.streaming,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        print("[Online ASR] request: POST \(url.absoluteString) apiType=mimo model=\(OnlineASRConfig.model) bytes=\(audioData.count)")
        AppLogger.shared.log(.onlineASR, "mimo transcribe start: \(audioData.count) bytes → \(url.absoluteString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw OnlineASRError.timeout
        } catch {
            throw OnlineASRError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OnlineASRError.network("无效响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            let detail = "POST \(url.absoluteString) HTTP \(http.statusCode) body=\(bodyPreview)"
            AppLogger.shared.log(.onlineASR, "mimo transcribe failed: \(detail)")
            print("[Online ASR] ERROR \(detail)")
            switch http.statusCode {
            case 401, 403:
                throw OnlineASRError.auth(message)
            case 429:
                throw OnlineASRError.rateLimited(message)
            default:
                throw OnlineASRError.apiError(http.statusCode, "\(message)（请求：\(url.absoluteString)）")
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        // 流式输出：SSE 逐 chunk 累加 delta.content；非流式：整体 JSON 解析。
        let text = OnlineASRConfig.streaming
            ? try Self.parseMimoSSE(data)
            : try parseMimoContent(data)
        print("[Online ASR] response: \(text.debugDescription) (mimo \(OnlineASRConfig.streaming ? "stream" : "non-stream"), \(Self.format(elapsed))s)")
        AppLogger.shared.log(.onlineASR, "mimo transcribe done in \(Self.format(elapsed))s")
        onProgress(1)
        return TranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [TranscriptionSegment(start: 0, end: nil, text: text)],
            detectedLanguage: nil
        )
    }

    /// 生效语种：配置指定（auto/zh/en）优先；配置为 auto 时按传入语言参数映射。
    private static func effectiveMimoLanguage(_ language: String?) -> String {
        let configured = OnlineASRConfig.mimoLanguage
        if configured != "auto" { return configured }
        return mapMimoLanguage(language)
    }

    /// MiMo 语言映射：zh-* → zh、en-* → en、其他 → auto。
    private static func mapMimoLanguage(_ language: String?) -> String {
        guard let language, !language.isEmpty, language.lowercased() != "auto" else { return "auto" }
        let lower = language.lowercased()
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("en") { return "en" }
        return "auto"
    }

    /// 解析 MiMo 流式响应（SSE）：data: {"choices":[{"delta":{"content":...}}]} 逐行累加。
    /// content 兼容字符串与分段数组（[{type:"text",text:...}]）。
    private static func parseMimoSSE(_ data: Data) throws -> String {
        guard let stream = String(data: data, encoding: .utf8) else {
            throw OnlineASRError.parseError
        }
        var result = ""
        for line in stream.split(separator: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            if let text = delta["content"] as? String {
                result += text
            } else if let parts = delta["content"] as? [[String: Any]] {
                result += parts.compactMap { $0["text"] as? String }.joined()
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnlineASRError.parseError }
        return trimmed
    }

    /// 解析 MiMo chat completion 响应：choices[0].message.content（字符串或分段数组）。
    private func parseMimoContent(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw OnlineASRError.parseError
        }
        if let text = message["content"] as? String, !text.isEmpty {
            return text
        }
        // content 分段数组：[{type: "text", text: "..."}]
        if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty {
                return texts.joined()
            }
        }
        throw OnlineASRError.parseError
    }

    private func upload(
        audioData: Data,
        mimeType: String,
        fileName: String,
        language: String?,
        prompt: String?,
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
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))
        if let language, !language.isEmpty {
            body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
            body.append(contentsOf: Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".utf8))
        }
        // ASR Prompt（热词）注入：OpenAI Whisper API `prompt` 字段。
        if let prompt, !prompt.isEmpty {
            body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
            body.append(contentsOf: Data("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\(prompt)\r\n".utf8))
        }
        body.append(contentsOf: Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let start = Date()
        // 完整请求调试日志：method / 最终 URL / headers（不打印密钥值）。
        let headers = request.allHTTPHeaderFields?.map { "\"\($0.key)\"" }.joined(separator: ", ") ?? ""
        AppLogger.shared.log(.onlineASR, "transcribe start: \(Int64(audioData.count)) bytes → POST \(endpoint.absoluteString) headers=[\(headers)]")
        print("[Online ASR] request: POST \(endpoint.absoluteString) baseURL=\(OnlineASRConfig.baseURL) apiType=\(OnlineASRConfig.apiType.rawValue) bytes=\(audioData.count)")

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
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            let elapsed = Date().timeIntervalSince(start)
            // 错误增强：请求 URL + 状态码 + 服务器返回内容。
            let detail = "POST \(endpoint.absoluteString) HTTP \(http.statusCode) body=\(bodyPreview)"
            AppLogger.shared.log(.onlineASR, "transcribe failed: \(detail) after \(Self.format(elapsed))s")
            print("[Online ASR] ERROR \(detail)")
            switch http.statusCode {
            case 401, 403:
                throw OnlineASRError.auth(message)
            case 429:
                throw OnlineASRError.rateLimited(message)
            default:
                throw OnlineASRError.apiError(http.statusCode, "\(message)（请求：\(endpoint.absoluteString)）")
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
        // 无时间戳（json 响应无 segments）：回落单段（时间戳缺失，由上层 offset）。
        // 不估算虚假时间戳，避免破坏 AppState 的 seal 推进。
        if segments.isEmpty, !fullText.isEmpty {
            segments = [TranscriptionSegment(start: 0, end: nil, text: fullText)]
        }
        return TranscriptionResult(text: fullText, segments: segments, detectedLanguage: detected)
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

    /// 转录端点：
    /// - OpenAI Compatible：normalize（防 /v1 重复）后拼 /audio/transcriptions；
    /// - Custom Endpoint：用户填写的完整端点原样使用（不做路径加工）。
    private func transcriptionsEndpoint() -> String {
        let base = OnlineASRConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if OnlineASRConfig.apiType == .custom {
            return base
        }
        let normalized = Self.normalizedBaseURL(base)
        let trimmed = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
        if trimmed.hasSuffix("/audio/transcriptions") { return trimmed }
        return trimmed + "/audio/transcriptions"
    }

    /// {base}/models。
    private func modelsEndpoint() -> String {
        let base = Self.normalizedBaseURL(OnlineASRConfig.baseURL)
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + "/models"
    }

    /// 端点归一化（OpenAI Compatible）：
    /// - 完整端点（以 /audio/transcriptions 或 /chat/completions 结尾）原样返回；
    /// - 重复 /v1/v1 去重为 /v1；
    /// - 路径无 v1 段时补 /v1 前缀。
    static func normalizedBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme != nil, components.host != nil else {
            return trimmed
        }
        var path = components.path
        // 完整端点：不再加工。
        if path.hasSuffix("/audio/transcriptions") || path.hasSuffix("/chat/completions") {
            return trimmed
        }
        // 重复 /v1/v1 → /v1（直到无重复）。
        while path.contains("/v1/v1") {
            path = path.replacingOccurrences(of: "/v1/v1", with: "/v1")
        }
        if !path.split(separator: "/").contains("v1") {
            path = "/v1" + path
        }
        components.path = path
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
