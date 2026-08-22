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

    private let supportedExtensions: Set<String> = ["gguf", "bin", "whisper"]

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
