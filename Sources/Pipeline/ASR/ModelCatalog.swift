import Foundation
import Observation

// MARK: - Model Catalog

/// Inference engine a catalog model runs on.
enum ModelEngine: Equatable {
    /// whisper.cpp GGML model — a single .bin file.
    case whisper
    /// NVIDIA Nemotron streaming ASR via FluidAudio (Core ML / ANE) — a
    /// directory bundle (encoder/decoder/joint .mlmodelc + metadata + tokenizer).
    case nemotron
    /// Alibaba Qwen3-ASR GGUF（30 种语言 + 22 种中文方言，自动语种识别与时间戳）。
    /// 注意：当前构建的 whisper.cpp 尚不支持该架构，选择后可下载，但推理需要
    /// 后续集成 ggml/Qwen3-ASR 后端（详见 TranscriptionService 中的明确报错）。
    case qwen3asr
    /// 阿里 FunASR ONNX 模型（SenseVoice / Paraformer / Fun-ASR-Nano），
    /// 经 sherpa-onnx 后端推理。
    case funasr
}

/// Where a catalog model's bytes come from.
enum DownloadSource: Equatable {
    /// Single file downloaded to Models/<fileName>.
    case file(URL)
    /// Every file under `folder` in a Hugging Face repo, downloaded into the
    /// Models/<fileName>/ directory (tree listed via the HF API at download time).
    case hfFolder(repo: String, folder: String)
}

/// A speech-recognition model available for in-app download.
struct WhisperModelInfo: Identifiable, Equatable {
    let id: String
    let displayName: String
    let detail: String
    /// On-disk name inside the Models directory: a file (whisper) or a directory (nemotron).
    let fileName: String
    let source: DownloadSource
    let approxBytes: Int64
    var engine: ModelEngine = .whisper
    /// 可选的多模态音频投影文件（llama.cpp mmproj 路线）。
    /// transcribe.cpp 的 all-in-one Qwen3-ASR GGUF 不需要。
    var mmprojURL: URL? = nil

    var approxSizeText: String {
        ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    /// All downloadable models. Breeze-ASR-25 is the default (best for
    /// Mandarin/Taiwanese); Nemotron is NVIDIA's multilingual streaming model
    /// running on the Neural Engine; the rest are official whisper.cpp conversions.
    static let all: [WhisperModelInfo] = [
        WhisperModelInfo(
            id: "breeze-asr-25",
            displayName: "Breeze-ASR-25",
            detail: "Best for Mandarin and Taiwanese-accented speech",
            fileName: "ggml-model.bin",
            source: .file(URL(string: "https://huggingface.co/danielkao0421/Breeze-ASR-25-ggml/resolve/main/ggml-model.bin")!),
            approxBytes: 3_100_000_000
        ),
        WhisperModelInfo(
            id: "nemotron-3.5-multilingual",
            displayName: "Nemotron 3.5 Multilingual",
            detail: "NVIDIA streaming ASR, ~40 languages with punctuation, Neural Engine",
            fileName: "nemotron-3.5-multilingual-2240ms",
            source: .hfFolder(
                repo: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
                folder: "multilingual/2240ms"
            ),
            approxBytes: 665_000_000,
            engine: .nemotron
        ),
        WhisperModelInfo(
            id: "qwen3-asr-1.7b",
            displayName: "Qwen3-ASR-1.7B",
            detail: "Alibaba 多语言 ASR：30 种语言 + 22 种中文方言，自动语种检测。transcribe.cpp all-in-one GGUF（音频编码器内置，无需 mmproj）",
            fileName: "Qwen3-ASR-1.7B-Q8_0.gguf",
            source: .file(URL(string: "https://huggingface.co/handy-computer/Qwen3-ASR-1.7B-gguf/resolve/main/Qwen3-ASR-1.7B-Q8_0.gguf")!),
            approxBytes: 2_185_030_624,
            engine: .qwen3asr
        ),
        WhisperModelInfo(
            id: "large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            detail: "Near large-v3 quality, much faster",
            fileName: "ggml-large-v3-turbo.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!),
            approxBytes: 1_620_000_000
        ),
        WhisperModelInfo(
            id: "medium",
            displayName: "Whisper Medium",
            detail: "Good multilingual quality",
            fileName: "ggml-medium.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!),
            approxBytes: 1_530_000_000
        ),
        WhisperModelInfo(
            id: "small",
            displayName: "Whisper Small",
            detail: "Fast, decent quality",
            fileName: "ggml-small.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!),
            approxBytes: 488_000_000
        ),
        WhisperModelInfo(
            id: "base",
            displayName: "Whisper Base",
            detail: "Very fast, basic quality",
            fileName: "ggml-base.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!),
            approxBytes: 148_000_000
        ),
        WhisperModelInfo(
            id: "tiny",
            displayName: "Whisper Tiny",
            detail: "Fastest, lowest quality",
            fileName: "ggml-tiny.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!),
            approxBytes: 78_000_000
        ),
        // MARK: FunASR（sherpa-onnx ONNX 模型；runtime 后端接入中）
        // SenseVoice：sherpa-onnx 官方 int8 转换版（目录含 model.int8.onnx
        // + tokens.txt；Phase 1 已验证链路）。
        WhisperModelInfo(
            id: "sensevoice-small",
            displayName: "SenseVoice-Small",
            detail: "FunASR 多语实时：中英日韩粤，低延迟（实时推荐）",
            fileName: "sense-voice-zh-en-ja-ko-yue",   // 目录语义
            source: .hfFolder(
                repo: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
                folder: "."
            ),
            approxBytes: 230_000_000,
            engine: .funasr
        ),
        // Paraformer-zh-streaming：目录（encoder/decoder int8 + tokens），
        // 中英双语流式（OnlineRecognizer + 端点检测）。
        WhisperModelInfo(
            id: "paraformer-zh-streaming",
            displayName: "Paraformer-zh-streaming",
            detail: "FunASR 中文流式实时识别（中英双语，低延迟）",
            fileName: "streaming-paraformer-bilingual-zh-en",   // 目录语义
            source: .hfFolder(
                repo: "csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en",
                folder: "."
            ),
            approxBytes: 250_000_000,
            engine: .funasr
        ),
        // Paraformer-zh：离线高精度（支持时间戳），文件转录场景。
        WhisperModelInfo(
            id: "paraformer-zh",
            displayName: "Paraformer-zh",
            detail: "FunASR 中文高准确率离线识别（时间戳，文件/会议转录）",
            fileName: "paraformer-zh-2023-09-14",   // 目录语义
            source: .hfFolder(
                repo: "csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14",
                folder: "."
            ),
            approxBytes: 850_000_000,
            engine: .funasr
        ),
        // Fun-ASR-Nano（LLM 多语）：目录（encoder-adaptor/llm/embedding/tokenizer）。
        WhisperModelInfo(
            id: "fun-asr-nano",
            displayName: "Fun-ASR-Nano",
            detail: "FunASR 高质量多语识别（LLM，大型本地模型选项）",
            fileName: "fun-asr-nano-2512-int8",   // 目录语义
            source: .hfFolder(
                repo: "csukuangfj/sherpa-onnx-funasr-nano-2512-int8",
                folder: "."
            ),
            approxBytes: 900_000_000,
            engine: .funasr
        ),
    ]

    static func model(id: String) -> WhisperModelInfo? {
        all.first { $0.id == id }
    }

    static func model(fileName: String) -> WhisperModelInfo? {
        all.first { $0.fileName == fileName }
    }

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/Models")
    }

    static func path(for model: WhisperModelInfo) -> URL {
        modelDirectory.appendingPathComponent(model.fileName)
    }

    /// Whether everything the model needs is on disk (a directory bundle can
    /// exist but be missing files after an interrupted download).
    static func isComplete(_ model: WhisperModelInfo) -> Bool {
        let base = path(for: model)
        switch model.engine {
        case .whisper, .qwen3asr:
            return FileManager.default.fileExists(atPath: base.path)
        case .funasr:
            // 目录语义：目录存在且含主权重即视为完整（tokens 同目录约定）。
            return FileManager.default.fileExists(
                atPath: base.appendingPathComponent("model.int8.onnx").path)
        case .nemotron:
            let required = [
                "metadata.json",
                "tokenizer.json",
                "encoder.mlmodelc/weights/weight.bin",
            ]
            return required.allSatisfy {
                FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path)
            }
        }
    }
}

// MARK: - Model Manager

/// Tracks which models are on disk, in-flight downloads, and the user's
/// model selection (persisted in UserDefaults as "selectedModelFile").
@Observable
final class ModelManager {
    static let shared = ModelManager()

    private(set) var downloadedFileNames: Set<String> = []
    private var downloaders: [String: ModelDownloader] = [:]

    /// File name (in the Models directory) of the model used for transcription.
    /// Empty = automatic (custom path from Settings, else the default model).
    var selectedFileName: String {
        didSet { UserDefaults.standard.set(selectedFileName, forKey: "selectedModelFile") }
    }

    /// File name of the model used for live transcription during recording —
    /// usually a smaller, faster one than the main model. Empty = use the main
    /// transcription model.
    var liveFileName: String {
        didSet { UserDefaults.standard.set(liveFileName, forKey: "liveModelFile") }
    }

    private init() {
        selectedFileName = UserDefaults.standard.string(forKey: "selectedModelFile") ?? ""
        liveFileName = UserDefaults.standard.string(forKey: "liveModelFile") ?? ""
        refresh()
        for model in ModelCatalog.all {
            downloaders[model.id] = ModelDownloader(model: model) { [weak self] in
                self?.downloadFinished(model)
            }
        }
    }

    var downloadedModels: [WhisperModelInfo] {
        ModelCatalog.all.filter { downloadedFileNames.contains($0.fileName) }
    }

    var selectedModel: WhisperModelInfo? {
        guard !selectedFileName.isEmpty else { return nil }
        return ModelCatalog.model(fileName: selectedFileName)
    }

    var liveModel: WhisperModelInfo? {
        guard !liveFileName.isEmpty else { return nil }
        return ModelCatalog.model(fileName: liveFileName)
    }

    func isDownloaded(_ model: WhisperModelInfo) -> Bool {
        downloadedFileNames.contains(model.fileName)
    }

    func downloader(for model: WhisperModelInfo) -> ModelDownloader {
        downloaders[model.id]!
    }

    // MARK: - 统一操作门面
    //
    // 模型的选择 / 下载 / 取消 / 删除全部经 ModelManager 收口：
    // UI（设置页）只读状态、调门面方法，不直接驱动 ModelDownloader。

    /// 选择转录模型（仅允许已下载的模型）。
    func select(_ model: WhisperModelInfo) {
        guard isDownloaded(model) else { return }
        guard selectedFileName != model.fileName else { return }
        selectedFileName = model.fileName
        AppLogger.shared.log(.model, "Model selected: \(model.fileName)")
    }

    /// 开始/继续下载（重复调用安全：下载中直接忽略）。
    func startDownload(for model: WhisperModelInfo) {
        let downloader = downloader(for: model)
        guard downloader.state != .downloading else { return }
        AppLogger.shared.log(.model, "Download start: \(model.fileName)")
        downloader.startDownload()
    }

    /// 取消下载。
    func cancelDownload(for model: WhisperModelInfo) {
        AppLogger.shared.log(.model, "Download cancel: \(model.fileName)")
        downloader(for: model).cancelDownload()
    }

    /// Re-scan the Models directory. Catalog directory bundles only count as
    /// downloaded when all their required files are present.
    func refresh() {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path)) ?? []
        var names: Set<String> = []
        for name in entries {
            if let model = ModelCatalog.model(fileName: name) {
                if ModelCatalog.isComplete(model) { names.insert(name) }
            } else if !name.hasPrefix(".") {
                names.insert(name)
            }
        }
        downloadedFileNames = names
        // Drop a selection whose file no longer exists (deleted externally)
        if !selectedFileName.isEmpty && !downloadedFileNames.contains(selectedFileName) {
            selectedFileName = ""
        }
        if !liveFileName.isEmpty && !downloadedFileNames.contains(liveFileName) {
            liveFileName = ""
        }
    }

    func delete(_ model: WhisperModelInfo) {
        AppLogger.shared.log(.model, "Model deleted: \(model.fileName)")
        try? FileManager.default.removeItem(at: ModelCatalog.path(for: model))
        try? FileManager.default.removeItem(at: ModelDownloader.stagingDirectory(for: model))
        refresh()
    }

    /// Called on the main queue when a download completes. The user explicitly
    /// chose this model, so switch transcription to it right away.
    private func downloadFinished(_ model: WhisperModelInfo) {
        refresh()
        selectedFileName = model.fileName
        AppLogger.shared.log(.model, "Download finished: \(model.fileName)")
    }
}
