import Foundation
import CTranscribe

// MARK: - Qwen3-ASR GGUF 后端（transcribe.cpp / ggml + Metal）
//
// 架构对应：
//   ASR Backend
//   ├── WhisperCppBackend（whisper.cpp，现有路径）
//   ├── NemotronBackend（FluidAudio）
//   └── Qwen3ASRBackend（本类：Qwen3-ASR GGUF，CTranscribe.xcframework）
//
// 事实说明：Qwen3-ASR-1.7B 的公开 GGUF 是 transcribe.cpp 的 all-in-one
// 格式（音频编码器内置，无需 mmproj）。`mmprojURL` 保留给未来 llama.cpp
// mmproj 路线（可选）。
//
// 统一输出（与实时字幕管道兼容）：
//   text      → TranscriptionResult.text
//   startTime → TranscriptionSegment.start（GGUF 无时间戳输出时按音频位置估算）
//   endTime   → TranscriptionSegment.end
//   isFinal   → 由上游管道“密封”语义表达（sealed segment 即为最终句）

final class Qwen3ASRBackend {
    /// 所有 transcribe_* 调用都在同一条串行队列上执行（会话非线程安全）。
    private let queue = DispatchQueue(label: "com.whisperasr.qwen3asr", qos: .userInitiated)
    private let stateLock = NSLock()
    private var session: OpaquePointer?
    private var loadedModelPath: String?

    var isLoaded: Bool {
        stateLock.withLock { session != nil }
    }

    /// 加载 GGUF 模型（可选 mmproj，当前 all-in-one 格式不需要）。
    func ensureLoaded(modelURL: URL, mmprojURL: URL? = nil) async throws {
        let path = modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.processFailed("Qwen3-ASR 模型文件不存在：\(modelURL.lastPathComponent)")
        }
        if let mmprojURL, !FileManager.default.fileExists(atPath: mmprojURL.path) {
            throw TranscriptionError.processFailed("Qwen3-ASR mmproj 文件不存在：\(mmprojURL.lastPathComponent)")
        }

        // 已加载同一模型：直接复用（实时分块转录会反复调用）。
        if stateLock.withLock({ loadedModelPath == path }) { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.loadSession(modelPath: path)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 流式分块转录（16kHz 单声道 Float32 PCM，由实时管道按块调用）。
    func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult, Error>) in
            queue.async {
                do {
                    let text = try self.runOnSession(samples: samples)
                    continuation.resume(returning: TranscriptionResult(
                        text: text,
                        segments: Self.estimateSegments(
                            text: text,
                            sampleStart: 0,
                            sampleCount: samples.count
                        )
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 文件转录。
    func transcribe(
        fileURL: URL,
        language: String? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        let samples = try await AudioLoader.loadSamples(url: fileURL)
        let result = try await transcribe(samples: samples)
        onProgress(1)
        return result
    }

    func unload() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.closeSession()
                continuation.resume()
            }
        }
    }

    // MARK: - C API 封装（仅队列内调用）

    private func loadSession(modelPath: String) throws {
        closeSession()

        var out: OpaquePointer?
        let status = modelPath.withCString { cPath in
            transcribe_open_swift(cPath, &out)
        }
        guard status == TRANSCRIBE_OK, let out else {
            let detail = String(cString: transcribe_status_string(Int32(status.rawValue)))
            throw TranscriptionError.processFailed("Qwen3-ASR 模型加载失败：\(detail)")
        }
        stateLock.withLock {
            session = out
            loadedModelPath = modelPath
        }
    }

    private func runOnSession(samples: [Float]) throws -> String {
        guard let session = stateLock.withLock({ self.session }) else {
            throw TranscriptionError.processFailed("Qwen3-ASR 模型尚未加载。")
        }

        let status = samples.withUnsafeBufferPointer { buf in
            transcribe_run_swift(session, buf.baseAddress, Int32(buf.count))
        }
        guard status == TRANSCRIBE_OK else {
            let detail = String(cString: transcribe_status_string(Int32(status.rawValue)))
            throw TranscriptionError.processFailed("Qwen3-ASR 转录失败：\(detail)")
        }
        guard let cText = transcribe_full_text_swift(session) else { return "" }
        return String(cString: cText)
    }

    private func closeSession() {
        if let session = stateLock.withLock({ self.session }) {
            transcribe_close_swift(session)
        }
        stateLock.withLock {
            session = nil
            loadedModelPath = nil
        }
    }

    // MARK: - 统一输出映射

    /// GGUF 不输出时间戳时，按音频位置估算段边界（等分 + 句间停顿辅助）。
    /// 实时管道以 16kHz 采样；返回的 start/end 单位为秒（相对当前分块）。
    static func estimateSegments(
        text: String,
        sampleStart: Int,
        sampleCount: Int,
        sampleRate: Int = 16000
    ) -> [TranscriptionSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 按句子边界（。！？…；换行等）切分，避免整块一个时间戳。
        let sentences = trimmed
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?…；;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let effective = sentences.isEmpty ? [trimmed] : sentences
        let totalSeconds = Double(sampleCount) / Double(sampleRate)
        let step = totalSeconds / Double(effective.count)

        return effective.enumerated().map { index, sentence in
            TranscriptionSegment(
                start: Double(sampleStart) / Double(sampleRate) + Double(index) * step,
                end: Double(sampleStart) / Double(sampleRate) + Double(index + 1) * step,
                text: sentence
            )
        }
    }
}
