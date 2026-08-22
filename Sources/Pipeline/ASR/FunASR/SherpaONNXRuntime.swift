import Foundation

// MARK: - sherpa-onnx 后端（SherpaONNXRuntime）
//
// Swift → sherpa-onnx C API（c-api/c-api.h）→ ONNX Runtime。
// Commit 2 接入 xcframework 后在此实现真实推理；
// 当前为骨架：isAvailable=false，全部路径返回 runtime unavailable。
//
// 架构约束：本类型是唯一允许触碰 C API 的地方——
// FunASRProvider 只见 FunASRRuntime 协议；禁止在 Swift 里调 C++。

struct SherpaONNXRuntime: FunASRRuntime {
    var isAvailable: Bool { false }

    func load(modelURL: URL) async throws {
        throw TranscriptionError.processFailed("FunASR runtime unavailable")
    }

    func transcribe(pcm: [Float], sampleRate: Int) async throws -> ASRResult {
        throw TranscriptionError.processFailed("FunASR runtime unavailable")
    }

    func unload() async {}
}
