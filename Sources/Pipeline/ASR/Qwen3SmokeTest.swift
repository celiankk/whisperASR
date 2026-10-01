import Foundation

#if DEBUG

// MARK: - Qwen3-ASR 后端冒烟测试（DEBUG）
//
// 用法：WhisperASR --qwen3-smoke <model.gguf> <audio.wav>
// 直接走应用内的 Qwen3ASRBackend（CTranscribe 桥接）做一次真实转录，
// 输出文本后退出（0=成功，1=失败）。

@MainActor
enum Qwen3SmokeTest {
    /// 打印指定模型文件的 GGUF 架构与解析出的引擎（用于排查“上传没效果”）。
    static func runEngineCheck(path: String) {
        print("[EngineCheck] \(TranscriptionService.debugEngineDescription(forPath: path))")
        exit(0)
    }

    static func run(modelPath: String, wavPath: String) {
        Task {
            do {
                let samples = try await AudioLoader.loadSamples(url: URL(fileURLWithPath: wavPath))
                let backend = Qwen3ASRBackend()
                try await backend.ensureLoaded(modelURL: URL(fileURLWithPath: modelPath))
                let result = try await backend.transcribe(samples: samples[...])
                print("[Qwen3Smoke] segments=\(result.segments.count)")
                print("[Qwen3Smoke] text=\(result.text)")
                await backend.unload()
                print("[Qwen3Smoke] PASS")
                exit(0)
            } catch {
                print("[Qwen3Smoke] FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}

#endif
