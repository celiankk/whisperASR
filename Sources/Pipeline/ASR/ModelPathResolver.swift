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

    private static func resolveProjectRoot() -> String {
        let thisFile = #filePath
        let sourcesDir = (thisFile as NSString).deletingLastPathComponent
        return (sourcesDir as NSString).deletingLastPathComponent
    }
}
