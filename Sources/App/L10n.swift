import Foundation

// MARK: - 轻量 i18n（L10n）
//
// 不引入 SwiftUI String(localized:) 资源包机制（需 Xcode catalog 工序），
// 用代码内字典表：key → (zh, en)，按系统首选语言取值。
// 覆盖策略渐进：未登记的 key 原样返回（现有中文 UI 不受影响），
// 新代码/高频界面逐步接入。切换语言 = 改系统语言（下次启动生效）。
//
// 用法：L10n.t("key") / Text(L10n.t("settings.recognition"))

enum L10n {
    /// 当前 UI 语言（系统首选语言含 zh → 中文，否则英文）。
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? true
    }

    /// 字符串表：key → (中文, 英文)。
    private static let table: [String: (zh: String, en: String)] = [
        // 菜单栏
        "menubar.show": ("显示主窗口", "Show Main Window"),
        "menubar.record.start": ("开始录制（选择应用）", "Start Recording (Pick App)"),
        "menubar.record.stop": ("结束录制", "Stop Recording"),
        "menubar.engine": ("识别引擎", "ASR Engine"),
        "menubar.engine.local": ("本地模型", "Local Model"),
        "menubar.engine.online": ("在线", "Online"),
        "menubar.engine.apple": ("Apple", "Apple"),
        "menubar.passthrough": ("字幕浮层鼠标穿透", "Subtitle Overlay Click-through"),
        "menubar.obsWindow": ("OBS 字幕窗", "OBS Subtitle Window"),
        "menubar.asrLanguage": ("识别语言", "Recognition Language"),
        "menubar.translation": ("翻译语言", "Translation Language"),
        "menubar.quit": ("退出 WhisperASR", "Quit WhisperASR"),
        "menubar.engine.switched": ("识别引擎已切换", "ASR engine switched"),
        // 通用
        "common.back": ("返回转录", "Back to Transcripts"),
    ]

    /// 取本地化字符串；未登记 key 原样返回（渐进接入，不阻塞现有 UI）。
    static func t(_ key: String) -> String {
        guard let entry = table[key] else { return key }
        return isChinese ? entry.zh : entry.en
    }
}
