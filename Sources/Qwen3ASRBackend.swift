import Foundation

// MARK: - Qwen3-ASR GGUF 后端（transcribe.cpp / ggml + Metal）
//
// 架构对应：
//   ASR Backend
//   ├── WhisperCppBackend（whisper.cpp，本文件外的现有路径）
//   ├── NemotronBackend（FluidAudio）
//   └── Qwen3ASRBackend（本类：Qwen3-ASR GGUF）
//
// 事实说明：Qwen3-ASR-1.7B 的公开 GGUF 是 transcribe.cpp 的 all-in-one
// 格式（音频编码器已内置在模型文件中，仓库不含 mmproj 文件）。因此本后端
// 按单文件加载；`mmprojURL` 保留给未来 llama.cpp mmproj 路线（可选）。
//
// 统一输出（与实时字幕管道兼容）：
//   text      → TranscriptionResult.text
//   startTime → TranscriptionSegment.start
//   endTime   → TranscriptionSegment.end
//   isFinal   → 由上游管道“密封”语义表达（sealed segment 即为最终句）
//
// 运行时接缝：应用包 Resources 或 /usr/local/bin 下放置
// `qwen3-asr-cli`（输入：16kHz 单声道 f32 PCM stdin；输出：JSON 段）后即可启用。
// 当前版本尚未捆绑该运行时，调用会返回明确错误，绝不误走 whisper.cpp。

final class Qwen3ASRBackend {
    private let stateLock = NSLock()
    private var modelURL: URL?
    private var mmprojURL: URL?
    private var loaded = false

    /// 是否可用的 transcribe.cpp 运行时（可执行文件）。
    static var runtimeExecutableURL: URL? {
        let names = ["qwen3-asr-cli", "transcribe", "llama-asr"]
        var dirs: [URL] = []
        if let bundle = Bundle.main.resourceURL {
            dirs.append(bundle)
        }
        dirs.append(URL(fileURLWithPath: "/usr/local/bin"))
        for dir in dirs {
            for name in names {
                let candidate = dir.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    var isLoaded: Bool {
        stateLock.withLock { loaded }
    }

    /// 加载 GGUF 模型（可选 mmproj）。
    func ensureLoaded(modelURL: URL, mmprojURL: URL? = nil) async throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw TranscriptionError.processFailed("Qwen3-ASR 模型文件不存在：\(modelURL.lastPathComponent)")
        }
        if let mmprojURL, !FileManager.default.fileExists(atPath: mmprojURL.path) {
            throw TranscriptionError.processFailed("Qwen3-ASR mmproj 文件不存在：\(mmprojURL.lastPathComponent)")
        }
        guard Self.runtimeExecutableURL != nil else {
            throw TranscriptionError.processFailed(
                "Qwen3-ASR 本地推理运行时未安装。该模型使用 transcribe.cpp（ggml + Metal）运行，"
                + "请在应用 Resources 放置 qwen3-asr-cli（或 /usr/local/bin）后重试；"
                + "当前不会调用 whisper.cpp，架构不兼容问题已消除。"
            )
        }
        stateLock.withLock {
            self.modelURL = modelURL
            self.mmprojURL = mmprojURL
            self.loaded = true
        }
        // TODO: 在这里调用 transcribe.cpp 加载接口（llama_asr / qwen_asr C API）。
    }

    /// 流式分块转录（16kHz 单声道 Float32 PCM，由实时管道按块调用）。
    func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        try ensureReady()
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }
        // TODO: 调用 qwen3-asr-cli / transcribe.cpp API：
        //   stdin 写 PCM → 读取 JSON 段（text/start/end）→ 映射为 TranscriptionResult。
        // 当前未捆绑运行时，给出明确错误。
        throw TranscriptionError.processFailed(
            "Qwen3-ASR 运行时尚未捆绑：请先集成 transcribe.cpp（详见 Qwen3ASRBackend.swift 顶部说明）。"
        )
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
        stateLock.withLock {
            modelURL = nil
            mmprojURL = nil
            loaded = false
        }
        // TODO: 释放 transcribe.cpp 上下文。
    }

    private func ensureReady() throws {
        try stateLock.withLock {
            guard loaded else {
                throw TranscriptionError.processFailed("Qwen3-ASR 模型尚未加载。")
            }
        }
    }

    // MARK: - 统一输出映射

    /// GGUF 不输出时间戳时，按音频位置估算段边界（等分 + 句间停顿辅助）。
    /// 实时管道以 16kHz 采样；返回的 start/end 单位为秒。
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
