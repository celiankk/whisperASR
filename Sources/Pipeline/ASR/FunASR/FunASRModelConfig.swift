import Foundation

// MARK: - FunASR 模型文件配置（FunASRModelConfig）
//
// 每个模型的文件清单与目录布局（sherpa-onnx 官方转换包结构）。
// Runtime load(modelURL:) 按此定位权重/tokens；下载完整性校验同源。
//
// 两个已知的现实差异，都是硬编码文件名踩过的坑：
//
// 1) **同一模型的发布批次会改文件名/位置**。Fun-ASR-Nano 早期包用
//    `encoder-adaptor.int8.onnx` + 根目录 `tokenizer.json`，2025-12 后的包
//    改为 `encoder_adaptor.int8.onnx` + `Qwen3-0.6B/` 子目录。因此每个文件
//    登记为「逻辑角色 + 备选路径列表」，探测时取第一个存在的。
//
// 2) **nano 的 tokenizer 是目录而不是文件**。sherpa-onnx 的
//    `OfflineFunASRNanoModelConfig::Validate()` 检查
//    `<tokenizer>/vocab.json`、`<tokenizer>/merges.txt`、
//    `<tokenizer>/tokenizer.json` 三个文件，传文件路径必然加载失败
//    （`offline-model-config.cc`：nano/qwen3-asr 不需要 tokens.txt，
//    tokenizer 从目录加载）。故目录型角色用 `directoryContents` 声明
//    必须在目录内存在的文件。
//
// Runtime 与完整性校验都走 resolve()，避免两处各自硬编码文件名而漂移
//（此前 ModelCatalog 写死 `model.int8.onnx`，导致 streaming-paraformer /
// fun-asr-nano 下载成功却永远无法选中）。

/// 模型内的一个文件角色：备选路径 + （目录型）必须存在的目录内文件。
struct FunASRModelFile {
    /// 角色名（日志/错误信息用），例如 "encoder" / "tokens"。
    let role: String
    /// 备选相对路径（相对模型目录），按优先级排列。
    let candidates: [String]
    /// 非空 = 该路径应是目录，且目录内必须存在这些文件（顺序无关）。
    /// 空 = 普通文件。
    let directoryContents: [String]

    /// 普通文件角色。
    init(_ role: String, _ candidates: [String]) {
        self.role = role
        self.candidates = candidates
        self.directoryContents = []
    }

    /// 目录型角色（如 nano 的 tokenizer 目录）。
    init(_ role: String, directory candidates: [String], contents: [String]) {
        self.role = role
        self.candidates = candidates
        self.directoryContents = contents
    }

    /// 判断某个候选是否在目录内就位。
    func isSatisfied(candidate: String, in directory: URL) -> Bool {
        // `"."` = 模型目录自身（tokenizer 直接摊在根目录的旧包布局）。
        let url = candidate == "." ? directory : directory.appendingPathComponent(candidate)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        guard !directoryContents.isEmpty else { return true }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return directoryContents.allSatisfy {
            fm.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    /// 缺失时的可读描述。
    var displayRequirement: String {
        if directoryContents.isEmpty {
            return "\(role)(\(candidates.joined(separator: " 或 ")))"
        }
        let inner = directoryContents.joined(separator: "+")
        return "\(role)目录(\(candidates.joined(separator: " 或 "))，需含 \(inner))"
    }
}

struct FunASRModelConfig {
    let modelType: FunASRModelType
    /// 该模型需要的全部文件角色。
    let files: [FunASRModelFile]

    /// 首选路径列表（错误信息与兼容调用方用）。
    var requiredFiles: [String] { files.map { $0.candidates[0] } }

    /// 解析目录内实际就位的角色：role → 命中候选的相对路径。
    /// 缺失的角色不出现在结果里（调用方用 isComplete 判断完整性）。
    func resolve(in directory: URL) -> [String: String] {
        var found: [String: String] = [:]
        for file in files {
            for candidate in file.candidates
            where file.isSatisfied(candidate: candidate, in: directory) {
                found[file.role] = candidate
                break
            }
        }
        return found
    }

    /// 目录内文件完整性（缺文件 → 明确 load failed 而非推理期崩溃）。
    func isComplete(in directory: URL) -> Bool {
        resolve(in: directory).count == files.count
    }

    /// 缺失角色的可读描述（错误信息用）。
    func missingDescription(in directory: URL) -> String {
        let found = resolve(in: directory)
        return files
            .filter { found[$0.role] == nil }
            .map(\.displayRequirement)
            .joined(separator: ", ")
    }

    /// 按模型目录/文件路径推断配置（catalog fileName 匹配）。
    /// 目录名（catalog fileName）→ 模型类型与文件清单。
    /// 自定义路径目录若含对应特征文件也可识别（requiredFiles 探测）。
    static func config(for modelURL: URL) -> FunASRModelConfig {
        let name = modelURL.lastPathComponent
        // 目录名优先精确匹配（catalog fileName 约定）。
        switch name {
        case "streaming-paraformer-bilingual-zh-en": return .paraformerStreaming
        case "paraformer-zh-2023-09-14": return .paraformerZH
        case "fun-asr-nano-2512-int8": return .funASRNano
        case "sense-voice-zh-en-ja-ko-yue",
             "sense-voice-funasr-nano-2025-12-17": return .senseVoiceSmall
        default: break
        }
        // 自定义目录：按文件特征探测。nano 的特征最具体（llm+embedding），
        // 先判它；再判 streaming（encoder+decoder）；其余 model+tokens 同构，
        // 靠目录名区分 paraformer 与 SenseVoice。
        if FunASRModelConfig.funASRNano.isComplete(in: modelURL) { return .funASRNano }
        if FunASRModelConfig.paraformerStreaming.isComplete(in: modelURL) {
            return .paraformerStreaming
        }
        if FunASRModelConfig.paraformerZH.isComplete(in: modelURL),
           name.contains("paraformer") {
            return .paraformerZH
        }
        for candidate in [FunASRModelConfig.paraformerZH, FunASRModelConfig.senseVoiceSmall]
        where candidate.isComplete(in: modelURL) {
            return candidate
        }
        return .senseVoiceSmall   // SenseVoice 兜底
    }
}

// MARK: - 各模型的固定清单

extension FunASRModelConfig {
    /// Paraformer-zh-streaming：encoder/decoder + tokens（在线流式）。
    static let paraformerStreaming = FunASRModelConfig(
        modelType: .paraformerStreaming,
        files: [
            FunASRModelFile("encoder", ["encoder.int8.onnx", "encoder.onnx"]),
            FunASRModelFile("decoder", ["decoder.int8.onnx", "decoder.onnx"]),
            FunASRModelFile("tokens", ["tokens.txt"]),
        ])

    /// Paraformer-zh（离线）：单权重 + tokens。
    static let paraformerZH = FunASRModelConfig(
        modelType: .paraformerZH,
        files: [
            FunASRModelFile("model", ["model.int8.onnx", "model.onnx"]),
            FunASRModelFile("tokens", ["tokens.txt"]),
        ])

    /// Fun-ASR-Nano（LLM）：encoder adaptor + LLM + embedding + tokenizer 目录。
    /// 不需要 tokens.txt（sherpa-onnx 对 nano 从 tokenizer 目录取词表）。
    static let funASRNano = FunASRModelConfig(
        modelType: .funASRNano,
        files: [
            FunASRModelFile("encoder", [
                "encoder_adaptor.int8.onnx", "encoder-adaptor.int8.onnx",
                "encoder_adaptor.onnx",
            ]),
            FunASRModelFile("llm", ["llm.int8.onnx", "llm.fp32.onnx", "llm.onnx"]),
            FunASRModelFile("embedding", ["embedding.int8.onnx", "embedding.onnx"]),
            FunASRModelFile("tokenizer",
                            directory: [
                                "Qwen3-0.6B", "tokenizer", ".",
                            ],
                            contents: ["vocab.json", "merges.txt", "tokenizer.json"]),
        ])

    /// SenseVoice-Small（离线）：单权重 + tokens。
    static let senseVoiceSmall = FunASRModelConfig(
        modelType: .senseVoiceSmall,
        files: [
            FunASRModelFile("model", ["model.int8.onnx", "model.onnx"]),
            FunASRModelFile("tokens", ["tokens.txt"]),
        ])
}
