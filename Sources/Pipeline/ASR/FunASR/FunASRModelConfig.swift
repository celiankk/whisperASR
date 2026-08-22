import Foundation

// MARK: - FunASR 模型文件配置（FunASRModelConfig）
//
// 每个模型的文件清单与目录布局（sherpa-onnx 官方转换包结构）。
// Runtime load(modelURL:) 按此定位权重/tokens；下载完整性校验同源。

struct FunASRModelConfig {
    let modelType: FunASRModelType
    /// 模型目录内必须存在的文件（缺一即 load 失败，报 model load failed）。
    let requiredFiles: [String]

    /// 按模型目录/文件路径推断配置（catalog fileName 匹配）。
    static func config(for modelURL: URL) -> FunASRModelConfig {
        let name = modelURL.lastPathComponent
        switch name {
        case "paraformer-zh-streaming.onnx":
            return .init(modelType: .paraformerStreaming, requiredFiles: [
                "encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt",
            ])
        case "paraformer-zh.onnx":
            return .init(modelType: .paraformerZH, requiredFiles: [
                "model.int8.onnx", "tokens.txt",
            ])
        case "fun-asr-nano.onnx":
            return .init(modelType: .funASRNano, requiredFiles: [
                // Fun-ASR-Nano（Phase 3）：LLM 权重 + encoder + tokenizer。
                "model.int8.onnx", "encoder.int8.onnx", "tokens.txt",
            ])
        default:
            // SenseVoice-Small（Phase 1 默认）。
            return .init(modelType: .senseVoiceSmall, requiredFiles: [
                "model.int8.onnx", "tokens.txt",
            ])
        }
    }

    /// 目录内文件完整性（缺文件 → 明确 load failed 而非推理期崩溃）。
    func isComplete(in directory: URL) -> Bool {
        requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}
