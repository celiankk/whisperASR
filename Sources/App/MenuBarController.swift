import AppKit

// MARK: - 菜单栏快捷控制（MenuBarController）
//
// NSStatusItem 常驻菜单栏（管线之外的快捷入口）：
// - 显示主窗口 / 退出；
// - 录制：开始（走一体化浮层流程）/ 结束（finishRecording 收口）；
// - 识别引擎快速切换（本地 / 在线 / Apple）；
// - 字幕浮层鼠标穿透切换。
//
// 由 AppDelegate 持有（applicationDidFinishLaunching 接线），
// 弱引用 AppState / AudioRecorder——生命周期归 App 层。

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private weak var appState: AppState?
    private weak var audioRecorder: AudioRecorder?

    private override init() { super.init() }

    /// 接线并显示（App 启动完成时调用一次）。
    func setup(appState: AppState, audioRecorder: AudioRecorder) {
        self.appState = appState
        self.audioRecorder = audioRecorder
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "WhisperASR")
        item.menu = buildMenu()
        statusItem = item
    }

    /// 固定条目引用：menuWillOpen 只原地改标题/勾选/enabled，
    /// 绝不在菜单显示期间整体替换 statusItem.menu（AppKit 在打开遍历中
    /// 销毁正在显示的菜单是未定义行为 → 状态项图标消失）。
    private var recordItem: NSMenuItem?
    private var passthroughItem: NSMenuItem?
    private var engineItems: [(item: NSMenuItem, engine: ASREngineSelection)] = []
    private var asrLanguageItems: [(item: NSMenuItem, code: String)] = []
    private var targetLanguageItems: [(item: NSMenuItem, id: String)] = []

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // delegate：每次打开前原地刷新动态状态。
        menu.delegate = self

        let show = NSMenuItem(title: L10n.t("menubar.show"), action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())

        let record = NSMenuItem(
            title: (audioRecorder?.state == .recording)
                ? L10n.t("menubar.record.stop") : L10n.t("menubar.record.start"),
            action: #selector(toggleRecording), keyEquivalent: "r")
        record.target = self
        self.recordItem = record
        menu.addItem(record)

        let engine = NSMenuItem(title: L10n.t("menubar.engine"), action: nil, keyEquivalent: "")
        engine.submenu = buildEngineMenu()
        menu.addItem(engine)

        // 识别语言（whisper/nemotron/在线可手动指定；Qwen/Apple 显示说明）。
        menu.addItem(makeLanguageSubmenu())

        // 翻译目标语言。
        let translation = NSMenuItem(title: L10n.t("menubar.translation"), action: nil, keyEquivalent: "")
        translation.submenu = buildTranslationTargetMenu()
        menu.addItem(translation)

        menu.autoenablesItems = false
        let passthrough = NSMenuItem(
            title: L10n.t("menubar.passthrough"),
            action: #selector(togglePassthrough), keyEquivalent: "")
        passthrough.target = self
        passthrough.isEnabled = FloatingLetterOverlayController.shared.isVisible
        self.passthroughItem = passthrough
        menu.addItem(passthrough)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.t("menubar.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// 整体重建菜单（**仅在菜单关闭时调用**——选择动作后菜单已收起，
    /// 此时替换 statusItem.menu 安全；打开中替换是未定义行为，见 17.12）。
    /// 用于需要变更菜单结构的场景（识别语言子菜单跟随引擎切换）。
    private func rebuildMenu() {
        guard !isMenuOpen else { return }
        statusItem?.menu = buildMenu()
    }

    private var isMenuOpen = false

    /// 打开前原地刷新动态状态（不替换菜单实例）：
    /// 录制标题、穿透可用性、引擎/识别语言/翻译语言的 ✓ 标记。
    private func refreshDynamicState() {
        let recording = audioRecorder?.state == .recording || audioRecorder?.state == .saving
        recordItem?.title = recording ? L10n.t("menubar.record.stop") : L10n.t("menubar.record.start")
        passthroughItem?.isEnabled = FloatingLetterOverlayController.shared.isVisible

        let currentEngine = ASREngineSelection.current
        for (item, engine) in engineItems {
            let base = item.title.replacingOccurrences(of: " ✓", with: "")
            let selected = engine == currentEngine ||
                (currentEngine != .online && currentEngine != .apple && currentEngine != .funasr
                    && engine == .auto)
            item.title = selected ? base + " ✓" : base
        }

        let currentLang = UserDefaults.standard.string(forKey: "asrLanguage") ?? "auto"
        for (item, code) in asrLanguageItems {
            let base = item.title.replacingOccurrences(of: " ✓", with: "")
            item.title = code == currentLang ? base + " ✓" : base
        }

        let currentTarget = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
        for (item, id) in targetLanguageItems {
            let base = item.title.replacingOccurrences(of: " ✓", with: "")
            item.title = id == currentTarget ? base + " ✓" : base
        }
    }

    private func buildEngineMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let current = ASREngineSelection.current
        let options: [(String, ASREngineSelection)] = [
            (L10n.t("menubar.engine.local"), .auto),
            (L10n.t("menubar.engine.online"), .online),
            (L10n.t("menubar.engine.apple"), .apple)
        ]
        engineItems.removeAll()
        for (title, engine) in options {
            let item = NSMenuItem(
                title: (engine == current ||
                        (current != .online && current != .apple && current != .funasr
                            && engine == .auto))
                    ? title + " ✓" : title,
                action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = engine.rawValue
            engineItems.append((item, engine))
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - 动作

    @objc func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        refreshDynamicState()
    }

    @objc func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    @objc private func toggleRecording() {
        guard let appState, let recorder = audioRecorder else { return }
        if recorder.state == .recording || recorder.state == .saving {
            Task { @MainActor in
                await appState.finishRecording(recorder: recorder)
                FloatingLetterOverlayHost.shared.dismiss()
            }
        } else {
            FloatingLetterOverlayHost.shared.startRecordingFlow(
                appState: appState, recorder: recorder) {
                FloatingLetterOverlayHost.shared.dismiss()
            }
        }
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = ASREngineSelection(rawValue: raw),
              let settings = appStateSettings() else { return }
        // 走配置对象（didSet 持久化 + @Observable 通知）——主窗口设置页
        // 与菜单栏双向同步；直接写 UserDefaults 会绕过 UI 通知。
        settings.asr.asrEngine = engine
        // 菜单已随选择关闭：此时重建结构安全（识别语言子菜单需跟随引擎）。
        rebuildMenu()
        appState?.showToast("\(L10n.t("menubar.engine.switched"))：\(engine == .apple ? "Apple" : engine == .online ? L10n.t("menubar.engine.online") : L10n.t("menubar.engine.local"))")
    }

    /// ConfigurationManager 弱引用（appState.attach 注入的同一实例）。
    private weak var configurationManager: ConfigurationManager?

    /// 取配置管理器（AppState 环境里持有的同一份）。
    private func appStateSettings() -> ConfigurationManager? {
        if let configurationManager { return configurationManager }
        guard let appState else { return nil }
        // AppState 不直接持有 manager；经运行时注入链取共享单例等价物。
        configurationManager = .shared
        return configurationManager
    }

    /// 显示主窗口：精确找 WhisperASR 主内容窗口（canBecomeMain 的普通
    /// 窗口，排除状态栏/面板），激活应用并前置。原实现取第一个可成为
    /// main 的窗口——浮层/弹窗存在时可能选错目标导致"点击无效"。
    @objc private func showMainWindow() {
        let mainWindow = NSApp.windows.first { window in
            window.canBecomeMain && window.isVisible
                && !(window is NSPanel)
                && window.frame.width > 400   // 排除紧凑浮层/小弹窗
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePassthrough() {
        FloatingLetterOverlayController.shared.togglePassthroughFromMenu()
    }

    /// 识别语言子菜单：**每次打开时重建**（跟随所选服务变化）——
    /// - whisper/nemotron/在线：自动检测 + whisper 语言表；
    /// - Qwen：自动检测说明（不支持手动指定）；
    /// - **Apple：直接列出已安装语言包供选择**（写 appleSpeechLocale，
    ///   与设置页「当前语言」同一配置）。
    /// 选择动作后菜单关闭，rebuildMenu 安全（见 selectEngine）。
    private func makeLanguageSubmenu() -> NSMenuItem {
        let engine = ASREngineSelection.current
        switch engine {
        case .apple:
            return appleLocaleSubmenu()
        case .qwen:
            let container = NSMenuItem(title: L10n.t("menubar.asrLanguage"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let item = NSMenuItem(
                title: "Qwen3-ASR 自动语种检测，不支持手动指定",
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            container.submenu = submenu
            return container
        default:
            return whisperLanguageSubmenu()
        }
    }

    /// Apple 引擎：语言包选择（installedLocales 可选），写 appleSpeechLocale。
    private func appleLocaleSubmenu() -> NSMenuItem {
        let container = NSMenuItem(title: L10n.t("menubar.asrLanguage"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let installed = AppleSpeechManager.shared.installedLocaleIdentifiers()
        let current = UserDefaults.standard.string(forKey: "appleSpeechLocale") ?? ""
        asrLanguageItems.removeAll()
        for locale in installed.sorted() {
            let name = Locale.current.localizedString(forIdentifier: locale) ?? locale
            let title = "\(name)（\(locale)）"
            let item = NSMenuItem(title: locale == current ? title + " ✓" : title,
                                  action: #selector(selectAppleLocale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = locale
            asrLanguageItems.append((item: item, code: locale))
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            let item = NSMenuItem(title: "暂无已安装语言包", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        container.submenu = submenu
        return container
    }

    /// 非 Apple 引擎：whisper 全语言表（自动检测 + 前 30）。
    private func whisperLanguageSubmenu() -> NSMenuItem {
        let container = NSMenuItem(title: L10n.t("menubar.asrLanguage"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let current = UserDefaults.standard.string(forKey: "asrLanguage") ?? "auto"
        asrLanguageItems.removeAll()
        let autoItem = languageItem("自动检测", code: "auto", current: current)
        asrLanguageItems.append((item: autoItem, code: "auto"))
        submenu.addItem(autoItem)
        submenu.addItem(.separator())
        for lang in TranscriptionService.availableLanguages().prefix(30) {
            let item = languageItem("\(lang.name)（\(lang.code)）",
                                    code: lang.code, current: current)
            asrLanguageItems.append((item: item, code: lang.code))
            submenu.addItem(item)
        }
        container.submenu = submenu
        return container
    }

    @objc private func selectAppleLocale(_ sender: NSMenuItem) {
        guard let locale = sender.representedObject as? String else { return }
        ConfigurationManager.shared.asr.appleSpeechLocale = locale
        appState?.showToast("Apple 识别语言：\(locale)")
    }

    private func languageItem(_ title: String, code: String, current: String) -> NSMenuItem {
        let item = NSMenuItem(title: code == current ? title + " ✓" : title,
                              action: #selector(selectASRLanguage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = code
        return item
    }

    /// 翻译目标语言子菜单：按当前翻译方式显示该后端支持的目标语言。
    private func buildTranslationTargetMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let mode = TranslationMode.current

        guard mode != .off else {
            let item = NSMenuItem(title: "翻译已关闭（设置 → 翻译 → 翻译方式开启后可选语言）",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }

        // 按后端能力过滤：Apple=系统翻译支持集；本地 LLM=常用三语；在线=全列表。
        let languages: [TargetLanguage]
        switch mode {
        case .apple:
            languages = TargetLanguage.available.filter {
                ["zh-Hans", "zh-Hant", "en", "ja", "ko"].contains($0.id)
            }
        case .localModel:
            languages = TargetLanguage.available.filter {
                ["en", "zh-Hans", "ja"].contains($0.id)
            }
        case .onlineAPI:
            languages = TargetLanguage.available
        case .off:
            languages = []
        }

        let current = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
        guard !languages.isEmpty else {
            let item = NSMenuItem(title: "当前翻译方式暂无可用语言", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }
        targetLanguageItems.removeAll()
        for lang in languages {
            let title = "\(lang.nativeName)（\(lang.id)）"
            let item = NSMenuItem(title: lang.id == current ? title + " ✓" : title,
                                  action: #selector(selectTargetLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.id
            targetLanguageItems.append((item, lang.id))
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectASRLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        // 走 ConfigurationManager 共享单例的 ASR 配置（Observable 通知）。
        ConfigurationManager.shared.asr.asrLanguage = code
        appState?.showToast(code == "auto" ? "识别语言：自动检测" : "识别语言：\(code)")
    }

    @objc private func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ConfigurationManager.shared.translation.targetLanguage = id
        appState?.showToast("翻译目标语言已切换")
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}


extension MenuBarController: NSMenuDelegate {}
