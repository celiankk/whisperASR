import Foundation
import Observation

// MARK: - Model Catalog

/// A whisper GGML model available for in-app download.
struct WhisperModelInfo: Identifiable, Equatable {
    let id: String
    let displayName: String
    let detail: String
    let fileName: String
    let url: URL
    let approxBytes: Int64

    var approxSizeText: String {
        ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    /// All downloadable models. Breeze-ASR-25 is the default (best for
    /// Mandarin/Taiwanese); the rest are official whisper.cpp conversions.
    static let all: [WhisperModelInfo] = [
        WhisperModelInfo(
            id: "breeze-asr-25",
            displayName: "Breeze-ASR-25",
            detail: "Best for Mandarin and Taiwanese-accented speech",
            fileName: "ggml-model.bin",
            url: URL(string: "https://huggingface.co/danielkao0421/Breeze-ASR-25-ggml/resolve/main/ggml-model.bin")!,
            approxBytes: 3_100_000_000
        ),
        WhisperModelInfo(
            id: "large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            detail: "Near large-v3 quality, much faster",
            fileName: "ggml-large-v3-turbo.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
            approxBytes: 1_620_000_000
        ),
        WhisperModelInfo(
            id: "medium",
            displayName: "Whisper Medium",
            detail: "Good multilingual quality",
            fileName: "ggml-medium.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            approxBytes: 1_530_000_000
        ),
        WhisperModelInfo(
            id: "small",
            displayName: "Whisper Small",
            detail: "Fast, decent quality",
            fileName: "ggml-small.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            approxBytes: 488_000_000
        ),
        WhisperModelInfo(
            id: "base",
            displayName: "Whisper Base",
            detail: "Very fast, basic quality",
            fileName: "ggml-base.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            approxBytes: 148_000_000
        ),
        WhisperModelInfo(
            id: "tiny",
            displayName: "Whisper Tiny",
            detail: "Fastest, lowest quality",
            fileName: "ggml-tiny.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            approxBytes: 78_000_000
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

    private init() {
        selectedFileName = UserDefaults.standard.string(forKey: "selectedModelFile") ?? ""
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

    func isDownloaded(_ model: WhisperModelInfo) -> Bool {
        downloadedFileNames.contains(model.fileName)
    }

    func downloader(for model: WhisperModelInfo) -> ModelDownloader {
        downloaders[model.id]!
    }

    /// Re-scan the Models directory.
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path)) ?? []
        downloadedFileNames = Set(files)
        // Drop a selection whose file no longer exists (deleted externally)
        if !selectedFileName.isEmpty && !downloadedFileNames.contains(selectedFileName) {
            selectedFileName = ""
        }
    }

    func delete(_ model: WhisperModelInfo) {
        try? FileManager.default.removeItem(at: ModelCatalog.path(for: model))
        refresh()
    }

    /// Called on the main queue when a download completes. The user explicitly
    /// chose this model, so switch transcription to it right away.
    private func downloadFinished(_ model: WhisperModelInfo) {
        refresh()
        selectedFileName = model.fileName
    }
}
