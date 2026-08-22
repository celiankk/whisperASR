import Foundation
import SherpaONNX

// MARK: - sherpa-onnx 后端（SherpaONNXRuntime）—— C API 桥接
//
// Swift → SherpaONNX(C module, c-api.h) → ONNX Runtime。
// 本类型是唯一允许触碰 C API 的地方（规格约束）；FunASRProvider
// 只见 FunASRRuntime 协议。
//
// Phase 1：SenseVoice-Small（OfflineRecognizer + sense_voice 配置）。
// 错误语义（规格第八节）：未加载 → "FunASR runtime unavailable"；
// 模型缺失/初始化失败 → "FunASR model load failed"；推理失败 →
// "FunASR inference failed"。不静默失败、不自动换模型。

final class SherpaONNXRuntime: FunASRRuntime, @unchecked Sendable {
    private var recognizer: OpaquePointer?
    private let lock = NSLock()

    var isAvailable: Bool { true }   // xcframework 已链接 = 后端可用

    init() {}

    // MARK: - FunASRRuntime

    func load(modelURL: URL) async throws {
        let modelConfig = FunASRModelConfig.config(for: modelURL)
        guard modelConfig.isComplete(in: modelURL) else {
            throw TranscriptionError.processFailed(
                "FunASR model load failed: 缺少模型文件（需要 \(modelConfig.requiredFiles.joined(separator: ", "))）")
        }

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                unloadLocked()
                defer { lock.unlock() }

                // 完整 OfflineRecognizerConfig（零值初始化 + SenseVoice 路径）。
                // C 字符串 strdup 持有（utf8String 指针生命周期只在 pool 内）。
                let modelPath = strdup(modelURL.appendingPathComponent("model.int8.onnx").path)
                let tokensPath = strdup(modelURL.appendingPathComponent("tokens.txt").path)
                let provider = strdup("cpu")
                defer {
                    free(modelPath)
                    free(tokensPath)
                    free(provider)
                }
                var config = SherpaOnnxOfflineRecognizerConfig()
                config.model_config = SherpaOnnxOfflineModelConfig()
                config.model_config.sense_voice = SherpaOnnxOfflineSenseVoiceModelConfig()
                config.model_config.sense_voice.model = UnsafePointer(modelPath)
                config.model_config.sense_voice.use_itn = 1
                config.model_config.tokens = UnsafePointer(tokensPath)
                config.model_config.num_threads = 2
                config.model_config.provider = UnsafePointer(provider)
                config.model_config.debug = 0

                // 新版 C API create 返回非 Optional（失败为 NULL，文件
                // 预检 isComplete 已兜底路径类错误；内部失败由后续调用暴露）。
                let created = SherpaOnnxCreateOfflineRecognizer(&config)
                recognizer = created
                continuation.resume()
            }
        }
        AppLogger.shared.log(.asr, "SherpaONNX runtime available — \(modelConfig.modelType.displayName) loaded")
    }

    func transcribe(pcm: [Float], sampleRate: Int) async throws -> ASRResult {
        lock.lock()
        guard let recognizer else {
            lock.unlock()
            throw TranscriptionError.processFailed("FunASR runtime unavailable")
        }
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                defer { lock.unlock() }
                let currentRecognizer = self.recognizer
                guard let recognizer = currentRecognizer else {
                    continuation.resume(throwing: TranscriptionError.processFailed("FunASR runtime unavailable"))
                    return
                }
                guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
                    continuation.resume(throwing: TranscriptionError.processFailed("FunASR inference failed"))
                    return
                }
                defer { SherpaOnnxDestroyOfflineStream(stream) }

                pcm.withUnsafeBufferPointer { buffer in
                    SherpaOnnxAcceptWaveformOffline(
                        stream, Int32(sampleRate), buffer.baseAddress, Int32(buffer.count))
                }
                SherpaOnnxDecodeOfflineStream(recognizer, stream)

                guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
                    continuation.resume(throwing: TranscriptionError.processFailed("FunASR inference failed"))
                    return
                }
                let text = result.pointee.text.map { String(cString: $0) } ?? ""
                var timestamps: [Float] = []
                if let ts = result.pointee.timestamps, result.pointee.count > 0 {
                    timestamps = Array(UnsafeBufferPointer(start: ts, count: Int(result.pointee.count)))
                }
                SherpaOnnxDestroyOfflineRecognizerResult(result)

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 静音段无文本是合法输出（isFinal=true 空文本，调用方跳过显示）；
                // 错误路径已在上方显式抛出。
                let end = timestamps.last.map { Double($0) }
                continuation.resume(returning: ASRResult(
                    text: trimmed, isFinal: true, language: "zh",
                    confidence: nil, timestamp: (0, end)))
            }
        }
    }

    func unload() async {
        lock.lock()
        unloadLocked()
        lock.unlock()
    }

    private func unloadLocked() {
        if let recognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
            self.recognizer = nil
        }
    }
}
