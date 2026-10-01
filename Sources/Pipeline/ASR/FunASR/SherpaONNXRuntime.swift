import Foundation
import SherpaONNX

// MARK: - sherpa-onnx 后端（SherpaONNXRuntime）—— C API 桥接
//
// Swift → SherpaONNX(C module, c-api.h) → ONNX Runtime。
// 本类型是唯一允许触碰 C API 的地方（规格约束）；FunASRProvider
// 只见 FunASRRuntime 协议。
//
// 支持矩阵：
// - senseVoiceSmall / paraformerZH / funASRNano：OfflineRecognizer
//   （整段推理；按模型类型构造对应 config；时间戳透传）；
// - paraformerStreaming：OnlineRecognizer + 持久 stream（会话状态跨
//   transcribe 保留——只喂新增音频，端点检测 Reset 开新段；
//   累积文本经公共前缀 diff 转增量，语义与 Apple waitForTextGrowth 一致）。
//
// 错误语义（规格第八节）：未加载 → "FunASR runtime unavailable"；
// 模型缺失/初始化失败 → "FunASR model load failed"；推理失败 →
// "FunASR inference failed"。不静默失败、不自动换模型。

final class SherpaONNXRuntime: FunASRRuntime, @unchecked Sendable {
    // Offline（senseVoice / paraformerZH / funASRNano）
    private var offlineRecognizer: OpaquePointer?
    // Online（paraformerStreaming）
    private var onlineRecognizer: OpaquePointer?
    private var onlineStream: OpaquePointer?
    /// 流式已输出基线（公共前缀 diff 用；endpoint reset 时清零）。
    private var streamedBaseline = ""
    private var loadedType: FunASRModelType?
    private let lock = NSLock()

    var isAvailable: Bool { true }   // xcframework 已链接 = 后端可用

    init() {}

    // MARK: - FunASRRuntime

    func load(modelURL: URL) async throws {
        let modelConfig = FunASRModelConfig.config(for: modelURL)
        guard modelConfig.isComplete(in: modelURL) else {
            let missing = modelConfig.missingDescription(in: modelURL)
            throw TranscriptionError.processFailed(
                "FunASR model load failed: 缺少模型文件（\(missing)）")
        }
        // 解析实际文件名（同一模型的不同发布批次文件名/位置不同，
        // 见 FunASRModelConfig 头注）——下游按角色取路径，不再自行拼名。
        let resolvedFiles = modelConfig.resolve(in: modelURL)

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                unloadLocked()
                defer { lock.unlock() }
                switch modelConfig.modelType {
                case .paraformerStreaming:
                    loadOnline(modelURL: modelURL)
                case .senseVoiceSmall, .paraformerZH, .funASRNano:
                    loadOffline(modelURL: modelURL, type: modelConfig.modelType,
                                files: resolvedFiles)
                }
                loadedType = modelConfig.modelType
                continuation.resume()
            }
        }
        AppLogger.shared.log(.asr, "SherpaONNX runtime available — \(modelConfig.modelType.displayName) loaded")
    }

    func transcribe(pcm: ArraySlice<Float>, sampleRate: Int) async throws -> ASRResult {
        lock.lock()
        let type = loadedType
        lock.unlock()
        guard let type else {
            throw TranscriptionError.processFailed("FunASR runtime unavailable")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                defer { lock.unlock() }
                let result: ASRResult
                switch type {
                case .paraformerStreaming:
                    result = transcribeOnline(pcm: pcm, sampleRate: sampleRate)
                case .senseVoiceSmall, .paraformerZH, .funASRNano:
                    result = transcribeOffline(pcm: pcm, sampleRate: sampleRate)
                }
                continuation.resume(returning: result)
            }
        }
    }

    func unload() async {
        lock.lock()
        unloadLocked()
        lock.unlock()
    }

    // MARK: - 加载（Offline：SenseVoice / Paraformer-zh / Fun-ASR-Nano）

    /// strdup 包装（调用方 deallocate）。
    private func dup(_ text: String) -> UnsafeMutablePointer<CChar> {
        strdup(text)
    }

    private func loadOffline(modelURL: URL, type: FunASRModelType,
                             files: [String: String]) {
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.model_config = SherpaOnnxOfflineModelConfig()
        config.model_config.num_threads = 2
        config.model_config.debug = 0
        // strdup 生命周期：create 同步调用后统一 free。
        var owned: [UnsafeMutablePointer<CChar>] = []
        let provider = dup("cpu")
        owned.append(provider)
        config.model_config.provider = UnsafePointer(provider)
        // tokens.txt 仅 senseVoice/paraformer 需要；nano 从 tokenizer 目录取词表，
        // 传不存在的 tokens 路径会被 sherpa-onnx 校验拒绝
        //（offline-model-config.cc 对 nano 跳过 tokens 检查，但不设更干净）。
        if let tokensRel = files["tokens"] {
            let tokens = dup(modelURL.appendingPathComponent(tokensRel).path)
            owned.append(tokens)
            config.model_config.tokens = UnsafePointer(tokens)
        }

        switch type {
        case .senseVoiceSmall:
            config.model_config.sense_voice = SherpaOnnxOfflineSenseVoiceModelConfig()
            let model = dup(modelURL.appendingPathComponent(
                files["model"] ?? "model.int8.onnx").path)
            owned.append(model)
            config.model_config.sense_voice.model = UnsafePointer(model)
            config.model_config.sense_voice.use_itn = 1
            // 语言提示（可选）：设置「识别语言」映射到 sense_voice.language
            //（zh/en/ja/ko 四语提示；其余回落 auto）。
            let langHint = Self.senseVoiceLanguageHint(
                ConfigurationManager.shared.asr.effectiveASRLanguage)
            let hint = dup(langHint)
            owned.append(hint)
            config.model_config.sense_voice.language = UnsafePointer(hint)
        case .paraformerZH:
            config.model_config.paraformer = SherpaOnnxOfflineParaformerModelConfig()
            let model = dup(modelURL.appendingPathComponent(
                files["model"] ?? "model.int8.onnx").path)
            owned.append(model)
            config.model_config.paraformer.model = UnsafePointer(model)
        case .funASRNano:
            // Fun-ASR-Nano（LLM）：encoder adaptor + LLM + embedding + tokenizer 目录。
            // tokenizer 必须是**目录**（内含 vocab.json/merges.txt/tokenizer.json），
            // 传文件路径会在 sherpa-onnx 侧校验失败。
            config.model_config.funasr_nano = SherpaOnnxOfflineFunASRNanoModelConfig()
            let path = { (role: String, fallback: String) in
                self.dup(modelURL.appendingPathComponent(files[role] ?? fallback).path)
            }
            let encoder = path("encoder", "encoder_adaptor.int8.onnx")
            let llm = path("llm", "llm.int8.onnx")
            let embedding = path("embedding", "embedding.int8.onnx")
            let tokenizer = path("tokenizer", "Qwen3-0.6B")
            owned += [encoder, llm, embedding, tokenizer]
            config.model_config.funasr_nano.encoder_adaptor = UnsafePointer(encoder)
            config.model_config.funasr_nano.llm = UnsafePointer(llm)
            config.model_config.funasr_nano.embedding = UnsafePointer(embedding)
            config.model_config.funasr_nano.tokenizer = UnsafePointer(tokenizer)
        case .paraformerStreaming:
            break   // 不可达（load 分支已隔离）
        }
        defer { owned.forEach { $0.deallocate() } }

        offlineRecognizer = SherpaOnnxCreateOfflineRecognizer(&config)
    }

    // MARK: - 加载（Online：Paraformer-zh-streaming）

    private func loadOnline(modelURL: URL) {
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.model_config = SherpaOnnxOnlineModelConfig()
        config.model_config.num_threads = 2
        config.model_config.debug = 0

        var owned: [UnsafeMutablePointer<CChar>] = []
        let provider = dup("cpu")
        owned.append(provider)
        config.model_config.provider = UnsafePointer(provider)
        let encoder = dup(modelURL.appendingPathComponent("encoder.int8.onnx").path)
        let decoder = dup(modelURL.appendingPathComponent("decoder.int8.onnx").path)
        let tokens = dup(modelURL.appendingPathComponent("tokens.txt").path)
        owned += [encoder, decoder, tokens]
        config.model_config.paraformer = SherpaOnnxOnlineParaformerModelConfig()
        config.model_config.paraformer.encoder = UnsafePointer(encoder)
        config.model_config.paraformer.decoder = UnsafePointer(decoder)
        config.model_config.tokens = UnsafePointer(tokens)

        // 端点检测（静音断句）：尾静音 ~1.2s 断段，20s 上限强制断。
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = 1.2
        config.rule3_min_utterance_length = 20
        defer { owned.forEach { $0.deallocate() } }

        let created = SherpaOnnxCreateOnlineRecognizer(&config)
        onlineRecognizer = created
        onlineStream = SherpaOnnxCreateOnlineStream(created)
        streamedBaseline = ""
    }

    // MARK: - 推理（Offline）

    private func transcribeOffline(pcm: ArraySlice<Float>, sampleRate: Int) -> ASRResult {
        guard let recognizer = offlineRecognizer else {
            return ASRResult(text: "", isFinal: true, language: nil,
                             confidence: nil, timestamp: (0, nil))
        }
        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        pcm.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(
                stream, Int32(sampleRate), buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            return ASRResult(text: "", isFinal: true, language: nil,
                             confidence: nil, timestamp: (0, nil))
        }
        let text = result.pointee.text.map { String(cString: $0) } ?? ""
        var timestamps: [Float] = []
        if let ts = result.pointee.timestamps, result.pointee.count > 0 {
            timestamps = Array(UnsafeBufferPointer(start: ts, count: Int(result.pointee.count)))
        }
        SherpaOnnxDestroyOfflineRecognizerResult(result)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = timestamps.last.map { Double($0) }
        return ASRResult(text: trimmed, isFinal: true, language: "zh",
                         confidence: nil, timestamp: (0, end))
    }

    // MARK: - 推理（Online：增量 + 端点断段）

    private func transcribeOnline(pcm: ArraySlice<Float>, sampleRate: Int) -> ASRResult {
        guard let recognizer = onlineRecognizer, let stream = onlineStream else {
            return ASRResult(text: "", isFinal: false, language: nil,
                             confidence: nil, timestamp: (0, nil))
        }
        pcm.withUnsafeBufferPointer { buffer in
            SherpaOnnxOnlineStreamAcceptWaveform(
                stream, Int32(sampleRate), buffer.baseAddress, Int32(buffer.count))
        }
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }

        // 端点（静音断句）：当前段收口 → Reset 开新段，整段作 final 返回。
        if SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) == 1 {
            let segmentText = currentOnlineText(recognizer: recognizer, stream: stream)
            SherpaOnnxOnlineStreamReset(recognizer, stream)
            streamedBaseline = ""
            return ASRResult(text: segmentText, isFinal: true, language: "zh",
                             confidence: nil, timestamp: (0, nil))
        }

        // 未到端点：累积文本与基线公共前缀 diff → 增量（回退时输出修正）。
        let accumulated = currentOnlineText(recognizer: recognizer, stream: stream)
        let common = Self.commonPrefixCount(accumulated, streamedBaseline)
        let incremental = String(accumulated.dropFirst(common))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        streamedBaseline = accumulated
        // 空增量合法（静音轮）：isFinal=false 空文本，调度层跳过显示。
        return ASRResult(text: incremental, isFinal: false, language: "zh",
                         confidence: nil, timestamp: (0, nil))
    }

    private func currentOnlineText(recognizer: OpaquePointer, stream: OpaquePointer) -> String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return "" }
        let text = result.pointee.text.map { String(cString: $0) } ?? ""
        SherpaOnnxDestroyOnlineRecognizerResult(result)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        for (ca, cb) in zip(a, b) where ca == cb {
            count += 1
        }
        return count
    }

    /// asrLanguage（whisper 码）→ SenseVoice language hint
    ///（"" auto / zh / en / ja / ko；粤语 yue 不在 whisper 表语义内不映射）。
    static func senseVoiceLanguageHint(_ code: String?) -> String {
        guard let code else { return "" }
        switch code.lowercased() {
        case "zh", "en", "ja", "ko": return code.lowercased()
        default: return ""
        }
    }

    // MARK: - 释放

    private func unloadLocked() {
        if let onlineStream {
            SherpaOnnxDestroyOnlineStream(onlineStream)
            self.onlineStream = nil
        }
        if let onlineRecognizer {
            SherpaOnnxDestroyOnlineRecognizer(onlineRecognizer)
            self.onlineRecognizer = nil
        }
        if let offlineRecognizer {
            SherpaOnnxDestroyOfflineRecognizer(offlineRecognizer)
            self.offlineRecognizer = nil
        }
        streamedBaseline = ""
        loadedType = nil
    }
}
