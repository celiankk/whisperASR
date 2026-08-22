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
    /// 目录名（catalog fileName）→ 模型类型与文件清单。
    /// 自定义路径目录若含对应特征文件也可识别（requiredFiles 探测）。
    static func config(for modelURL: URL) -> FunASRModelConfig {
        let name = modelURL.lastPathComponent
        let candidates: [FunASRModelConfig] = [
            .init(modelType: .paraformerStreaming, requiredFiles: [
                "encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt",
            ]),
            .init(modelType: .paraformerZH, requiredFiles: [
                "model.int8.onnx", "tokens.txt",
            ]),
            .init(modelType: .funASRNano, requiredFiles: [
                "encoder-adaptor.int8.onnx", "llm.int8.onnx",
                "embedding.int8.onnx", "tokenizer.json",
            ]),
            .init(modelType: .senseVoiceSmall, requiredFiles: [
                "model.int8.onnx", "tokens.txt",
            ]),
        ]
        // 目录名优先精确匹配（catalog fileName 约定）。
        switch name {
        case "streaming-paraformer-bilingual-zh-en": return candidates[0]
        case "paraformer-zh-2023-09-14": return candidates[1]
        case "fun-asr-nano-2512-int8": return candidates[2]
        case "sense-voice-zh-en-ja-ko-yue": return candidates[3]
        default: break
        }
        // 自定义目录：按文件特征探测（encoder+decoder → streaming；
        // llm → nano；否则 paraformer/SenseVoice 同构回落 SenseVoice）。
        for candidate in candidates where candidate.isComplete(in: modelURL) {
            if candidate.modelType == .paraformerZH, name.contains("paraformer") {
                return candidate
            }
            if candidate.modelType != .paraformerZH {
                return candidate
            }
        }
        return candidates[3]   // SenseVoice 兜底
    }

    /// 目录内文件完整性（缺文件 → 明确 load failed 而非推理期崩溃）。
    func isComplete(in directory: URL) -> Bool {
        requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}
