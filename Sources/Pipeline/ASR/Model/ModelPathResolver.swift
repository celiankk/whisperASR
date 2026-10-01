import Foundation

// MARK: - 模型路径解析
//
// 1.4 中路径解析位于 TranscriptionService 内部；三个 Provider 与引擎识别
// 共用同一套规则，抽成独立解析器保证行为完全一致：
//   自定义路径（UserDefaults "modelPath"）
//     → 已选下载模型（"selectedModelFile" / "liveModelFile"）
//     → App Support 自动下载位置
//     → 项目内置（开发环境）

enum ModelPathResolver {
    static var appSupportModelPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/Models/ggml-model.bin").path
    }

    /// 当前转录模型路径：自定义路径优先（用户在“自定义模型”中上传/填写的
    /// 文件立即生效）；其次显式选择的已下载模型；最后回退 App Support /
    /// 项目内置。
    static func resolveModelPath() -> String {
        // 自定义模型路径优先（用户在“自定义模型”中上传/填写的文件立即生效）。
        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return custom
        }

        // Explicitly selected downloaded model (set via Settings or the toolbar picker)
        if let selected = UserDefaults.standard.string(forKey: "selectedModelFile"),
           !selected.isEmpty {
            let selectedPath = ModelCatalog.modelDirectory.appendingPathComponent(selected).path
            if FileManager.default.fileExists(atPath: selectedPath) {
                return selectedPath
            }
        }

        // Check App Support path (where auto-download saves the model)
        let appSupportPath = appSupportModelPath
        if FileManager.default.fileExists(atPath: appSupportPath) {
            return appSupportPath
        }

        // Fallback to project-relative path (development)
        let projectRoot = resolveProjectRoot()
        return (projectRoot as NSString).appendingPathComponent("Models/ggml-model.bin")
    }

    /// 实时转录模型路径：专用 live 选择（通常更小更快）存在时优先，
    /// 否则与主模型一致。
    static func resolveLiveModelPath() -> String {
        if let live = UserDefaults.standard.string(forKey: "liveModelFile"),
           !live.isEmpty {
            let livePath = ModelCatalog.modelDirectory.appendingPathComponent(live).path
            if FileManager.default.fileExists(atPath: livePath) {
                return livePath
            }
        }
        return resolveModelPath()
    }

    /// 项目根目录（仅开发环境回退用）。
    ///
    /// 由 `#filePath`（构建期源码绝对路径）上溯到仓库根。
    ///
    /// 早前实现写死「上溯 2 层」（当时本文件在 `Sources/Pipeline/ASR/`），
    /// 文件移入 `Model/` 子目录后没同步调整 → 回退路径指向
    /// `Sources/Pipeline/ASR/Models/ggml-model.bin`（不存在），
    /// 表现为「已下载了模型却报 Model not found」。
    /// 现在改为**按标记目录查找**而不是数层数：向上找到同时含
    /// `Package.swift` 的祖先目录即为仓库根，源码再挪位置也不会错。
    private static func resolveProjectRoot() -> String {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        // 上限保护：避免异常路径下无限上溯（正常 5 层内命中）。
        for _ in 0..<12 {
            if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }   // 已到文件系统根
            url = parent
        }
        // 找不到标记：退回「上溯 5 层」的经验值（本文件当前深度）。
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
    }
}
