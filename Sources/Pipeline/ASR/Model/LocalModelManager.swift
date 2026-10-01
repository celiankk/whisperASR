import Foundation
import Observation

// MARK: - 本地模型管理（LocalModelManager）
//
// 与网络下载（ModelManager / ModelDownloader）完全隔离：
// - LocalModelManager：文件扫描 / 本地加载（禁止调用任何网络 API）；
// - ModelManager / ModelDownloader：LM Studio 探测、在线下载。
//
// 扫描用户选择的目录中的 .gguf / .bin / .whisper 文件，
// 展示名称 / 大小 / 路径 / 状态；目录路径持久化到 UserDefaults。

struct LocalModelInfo: Identifiable, Equatable {
    let id: String        // 完整路径
    let name: String      // 文件名（去扩展名）
    let sizeBytes: Int64
    let path: String
    var status: String

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// 引擎归属（按扩展名 + GGUF 架构 + catalog 元数据判定）：
    /// .onnx→funasr；目录→nemotron；.gguf 读架构（qwen3_asr→qwen3asr，
    /// 其余→whisper）；.bin→whisper；catalog fileName 命中优先。
    var engine: ModelEngine {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        if let catalogModel = ModelCatalog.model(fileName: fileName) {
            return catalogModel.engine
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return .nemotron
        }
        switch url.pathExtension.lowercased() {
        case "onnx": return .funasr
        case "gguf":
            if let arch = GGUFInspector.architecture(atPath: path)?.lowercased(),
               arch.contains("qwen3_asr") || arch.contains("qwen3-asr") {
                return .qwen3asr
            }
            return .whisper
        default: return .whisper   // .bin 及其他（whisper ggml 系）
        }
    }

    /// 引擎显示名（分组标题用）。
    static func engineGroupName(_ engine: ModelEngine) -> String {
        switch engine {
        case .whisper: return "Whisper 模型"
        case .qwen3asr: return "Qwen3 模型"
        case .nemotron: return "Nemotron 模型"
        case .funasr: return "FunASR 模型"
        }
    }
}

@Observable
final class LocalModelManager {
    static let shared = LocalModelManager()

    private(set) var models: [LocalModelInfo] = []

    var directoryPath: String {
        didSet {
            UserDefaults.standard.set(directoryPath, forKey: "localModelDirectory")
            scan()
        }
    }

    private let supportedExtensions: Set<String> = ["gguf", "bin", "whisper", "onnx"]

    private init() {
        directoryPath = UserDefaults.standard.string(forKey: "localModelDirectory") ?? ""
        scan()
    }

    /// 扫描目录下的模型文件（纯文件系统操作，不联网）。
    func scan(path: String? = nil) {
        let dir = path ?? directoryPath
        models = []
        guard !dir.isEmpty else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let fm = FileManager.default
        for name in entries.sorted() {
            let ext = (name as NSString).pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            let fullPath = (dir as NSString).appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: fullPath))?[.size] as? NSNumber
            let displayName = (name as NSString).deletingPathExtension
            models.append(LocalModelInfo(
                id: fullPath,
                name: displayName,
                sizeBytes: size?.int64Value ?? 0,
                path: fullPath,
                status: "可用"
            ))
        }
    }

    func clearDirectory() {
        directoryPath = ""
    }
}
