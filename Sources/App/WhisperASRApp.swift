import SwiftUI
import AppKit
import ScreenCaptureKit
import Darwin

@main
struct WhisperASRApp: App {
    @State private var appState = AppState()
    @State private var audioPlayer = AudioPlayerManager()
    @State private var audioRecorder = AudioRecorder()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    init() {
        // macOS SwiftUI 已知崩溃防护：NSHostingView 在窗口缩放/显示周期内重入
        // 约束更新会触发 AppKit "Update Constraints in Window pass" 断言 abort。
        // 关闭该断言：AppKit 退化为日志记录，不再崩溃（见 newdme 第十三节）。
        UserDefaults.standard.set(false, forKey: "NSWindowAssertWhenDisplayCycleLimitReached")
        // 设置数据中心注入 AppState（字幕样式/翻译方式经 AppState 联动浮层）。
        ConfigurationManager.shared.attach(appState: appState)
        // 诊断日志：stdout/stderr 重定向到 ~/Library/Logs/WhisperASR/app.log（追加）。
        Self.redirectConsoleOutput()
    }

    /// 将 stdout/stderr 重定向到日志文件（排查 Apple 引擎/字幕链路问题时
    /// 直接读 app.log，无需 Console.app）。
    private static func redirectConsoleOutput() {
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/WhisperASR", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        if let stream = fopen(file.path, "a+") {
            dup2(fileno(stream), fileno(stdout))
            dup2(fileno(stream), fileno(stderr))
            setvbuf(stdout, nil, _IONBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)
        }
        print("\n===== WhisperASR launch \(Date()) =====")
    }

    var body: some Scene {
        Window("SonicScribe", id: "main") {
            ContentView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
            .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    // 重新注入配置中心：init 里的 attach 可能在 App 结构体被
                    // SwiftUI 重建时指向旧的（已丢弃的）AppState；onAppear 拿到的
                    // 一定是当前生效实例（幂等，覆盖注入无害）。
                    ConfigurationManager.shared.attach(appState: appState)
                    appDelegate.appState = appState
                    appDelegate.audioRecorder = audioRecorder
                    appDelegate.openWindow = openWindow
                    appDelegate.processPendingURL()
                    // 菜单栏快捷控制：必须在注入完成后 setup（此前触发时
                    // appState/audioRecorder 还是 nil → 状态项不出现）。
                    MenuBarController.shared.setup(appState: appState, audioRecorder: audioRecorder)
                    // FunASR sherpa-onnx 后端注册（Provider 经 Registry 透明取用）。
                    FunASRRuntimeRegistry.register(SherpaONNXRuntime())
                    AppLogger.shared.log(.asr, "SherpaONNX runtime available (xcframework linked)")
                    // Recover live transcription from a previous crash/hang
                    if appState.hasLiveRecoveryData {
                        appState.importRecoveredTranscription()
                    }
                }
                .onOpenURL { url in
                    appDelegate.handleURL(url)
                }
        }
        .defaultSize(width: 1000, height: 650)
        .commands {
#if DEBUG
            CommandMenu("调试") {
                // 仅用于预览字幕浮层样式，不控制浮层启停。
                Button("字幕浮层样式预览…") {
                    openWindow(id: "debug-subtitle")
                }
                // 悬浮授权窗测试：直接弹出（附着在系统设置下方的拖拽
                // 授权引导）——绕开设置页导航链路，便于验证与演示。
                Button("屏幕录制授权悬浮窗…") {
                    PermissionGuidePanelController.shared.show(
                        permissionName: "屏幕录制",
                        settingsURL: URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Button("浮层内存自检") {
                    FloatingLetterLeakTest.runAfterLaunch(appDelegate: appDelegate)
                }
            }
#endif
        }

        Window("Meeting Minutes", id: "minutes") {
            MinutesWindowView()
                .environment(appState)
        }
        .defaultSize(width: 720, height: 820)

        // Debug-only subtitle preview: manual text input → subtitle rendering.
        // Remove with Sources/DebugSubtitleView.swift and the "调试" menu above.
#if DEBUG
        Window("字幕浮层调试", id: "debug-subtitle") {
            DebugSubtitleView()
        }
        .defaultSize(width: 540, height: 400)
#endif

        Settings {
            SettingsView()
                .environment(appState)
                // 「系统状态」页（含延迟仪表盘）读取 AudioRecorder 状态——
                // 独立设置窗口缺这两个注入时 @Environment(Type.self) 直接
                // fatalError 崩溃（主窗口内嵌路径由 ContentView 注入，故只在
                // ⌘, 独立窗口复现）。
                .environment(audioPlayer)
                .environment(audioRecorder)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var audioRecorder: AudioRecorder?
    var openWindow: OpenWindowAction?
    /// 退出前收尾（停录 + finalize 音频）是否已启动；防重复退出请求重入。
    private var isFinishingBeforeTerminate = false
    private var pendingURL: URL?

    /// URL 双入口去重（URL + 时间窗）。
    ///
    /// 同一次打开会被派发两次：AppDelegate `application(_:open:)` 与 SwiftUI
    /// 的 `.onOpenURL`（:70）都调 handleURL。而 `autoStartRecording` 在置位
    /// 录制态之前要先 await SCShareableContent 枚举应用列表——这段窗口里
    /// 第二次调用看到的仍是「未录制」，于是重复启动录制。按 URL 内容 + 短
    /// 时间窗去重，只吞掉同一次打开的重复派发（用户过一会儿再打开同一 URL
    /// 仍会正常处理）。
    private var lastHandledURL: URL?
    private var lastHandledAt: Date?
    private static let urlDedupeWindow: TimeInterval = 2.0

    /// 本 App 接受的 URL scheme 集合。
    ///
    /// **事实来源 = Info.plist**（`CFBundleURLTypes` → `CFBundleURLSchemes`，
    /// 由 `Scripts/build_release.sh` 按品牌参数写入）。此前这里硬编码
    /// `url.scheme == "whisperasr"`：产品改名「声记 SonicScribe」后，打出的包
    /// 注册的是 `sonicscribe`，代码却只认旧 scheme → `open sonicscribe://record`
    /// 静默失效（改名断点）。
    ///
    /// 保留已知 scheme 作为兜底：`swift run` 直接跑可执行文件时没有 app
    /// bundle / Info.plist，且升级安装的用户可能仍持有旧 scheme 的快捷方式。
    static let acceptedURLSchemes: Set<String> =
        urlSchemes(fromInfoDictionary: Bundle.main.infoDictionary)

    /// 从 Info.plist 字典提取 URL scheme（纯逻辑，单测覆盖）。
    ///
    /// 抽成静态纯函数是为了让「改名后 scheme 是否被认」这条关键路径可单测——
    /// 测试跑在 test bundle 里，`Bundle.main` 的 plist 与 App 包不同。
    static func urlSchemes(fromInfoDictionary info: [String: Any]?) -> Set<String> {
        var schemes = Set<String>()
        if let types = info?["CFBundleURLTypes"] as? [[String: Any]] {
            for type in types {
                if let list = type["CFBundleURLSchemes"] as? [String] {
                    schemes.formUnion(list.map { $0.lowercased() })
                }
            }
        }
        // 兜底：`swift run` 裸跑可执行文件时没有 app bundle / Info.plist；
        // 且升级安装的用户可能仍持有旧 scheme 的快捷方式。
        schemes.formUnion(["whisperasr", "sonicscribe"])
        return schemes
    }

    /// 判定 URL 是否属于本 App（大小写不敏感）。
    static func owns(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return acceptedURLSchemes.contains(scheme)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let icon = AppIconGenerator.generate()
        NSApplication.shared.applicationIconImage = icon
        let imageView = NSImageView(image: icon)
        NSApplication.shared.dockTile.contentView = imageView
        NSApplication.shared.dockTile.display()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
#if DEBUG
        // 端到端评测工作台：--asr-bench <音频目录|文件> [选项]
        // （引擎 × 翻译通道矩阵跑真实音频；见 ASRBench）
        ASRBench.runIfRequested()
        // 引擎识别检查：--engine-check <model.gguf>
        if CommandLine.arguments.contains("--engine-check") {
            let args = CommandLine.arguments
            if args.count >= 3 {
                Qwen3SmokeTest.runEngineCheck(path: args[2])
            } else {
                print("usage: --engine-check <model.gguf>")
                exit(2)
            }
        }
        // Qwen3-ASR 后端冒烟测试：--qwen3-smoke <model.gguf> <audio.wav>
        if CommandLine.arguments.contains("--qwen3-smoke") {
            let args = CommandLine.arguments
            if args.count >= 4 {
                Qwen3SmokeTest.run(modelPath: args[2], wavPath: args[3])
            } else {
                print("usage: --qwen3-smoke <model.gguf> <audio.wav>")
                exit(2)
            }
        }
        // 一体化浮层内存自检：命令行带 --overlay-leak-test 启动即自动执行。
        if CommandLine.arguments.contains("--overlay-leak-test") {
            FloatingLetterLeakTest.runAfterLaunch(appDelegate: self)
        }
        // 旧浮层替换自检：命令行带 --overlay-replace-test 启动即自动执行。
        if CommandLine.arguments.contains("--overlay-replace-test") {
            FloatingLetterLeakTest.runReplaceTest(appDelegate: self)
        }
        // 应用列表首开自检：命令行带 --overlay-select-test 启动即自动执行。
        if CommandLine.arguments.contains("--overlay-select-test") {
            FloatingLetterLeakTest.runSelectTest(appDelegate: self)
        }
#endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, Self.owns(url) else { return }
        // If the app state is ready, handle immediately; otherwise queue it
        // (audioRecorder is injected by the main window's onAppear).
        if audioRecorder != nil {
            handleURL(url)
        } else {
            pendingURL = url
        }
    }

    func handleURL(_ url: URL) {
        guard Self.owns(url), url.host == "record",
              let audioRecorder else { return }

        // 双入口去重（见 lastHandledURL 注释）：同一次打开的第二次派发直接丢弃。
        let now = Date()
        if lastHandledURL == url, let last = lastHandledAt,
           now.timeIntervalSince(last) < Self.urlDedupeWindow {
            return
        }
        lastHandledURL = url
        lastHandledAt = now

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ key: String) -> String? {
            queryItems.first(where: { $0.name == key })?.value
        }
        func queryBool(_ key: String) -> Bool? {
            guard let val = queryValue(key) else { return nil }
            return val == "true" || val == "1" || val == "yes"
        }

        // Parse optional recording name
        if let name = queryValue("name"), !name.isEmpty {
            audioRecorder.customRecordingName = name
        }

        // Apply optional toggle overrides
        if let mic = queryBool("mic") {
            audioRecorder.includeMicrophone = mic
        }
        if let live = queryBool("live") {
            appState?.enableLiveTranscription = live
        }
        if let translate = queryBool("translate") {
            appState?.setTranslationMode(translate ? .onlineAPI : .off)
            // Translation requires live transcription
            if translate { appState?.enableLiveTranscription = true }
        }
        if let pin = queryBool("pin") {
            appState?.setRecordingAlwaysOnTop(pin)
        }

        // If already recording, just make sure the unified overlay is visible
        if audioRecorder.state == .recording {
            if let appState {
                Task { @MainActor in
                    FloatingLetterOverlayHost.shared.present(
                        appState: appState,
                        recorder: audioRecorder
                    )
                }
            }
            return
        }

        // If app parameter is provided, auto-start recording directly
        if let appName = queryValue("app"), !appName.isEmpty {
            autoStartRecording(appName: appName)
            return
        }

        // Otherwise enter the unified overlay's app-selection flow
        presentRecordingFlowForURL()
    }

    /// Find the named app and start recording automatically, skipping the picker.
    private func autoStartRecording(appName: String) {
        guard let audioRecorder, let appState else { return }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let myBundleID = Bundle.main.bundleIdentifier ?? "com.whisperasr"
                let appsWithWindows = Set(content.windows.map { $0.owningApplication?.bundleIdentifier })
                let apps = content.applications.filter {
                    $0.bundleIdentifier != myBundleID
                        && !$0.applicationName.isEmpty
                        && appsWithWindows.contains($0.bundleIdentifier)
                        && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
                }

                // Match by case-insensitive substring
                let lowerName = appName.lowercased()
                guard let matchedApp = apps.first(where: { $0.applicationName.lowercased().contains(lowerName) }) else {
                    await MainActor.run {
                        audioRecorder.error = "App \"\(appName)\" not found"
                        audioRecorder.availableApps = apps
                        audioRecorder.state = .ready
                        self.presentRecordingFlowForURL()
                    }
                    return
                }

                await MainActor.run {
                    audioRecorder.state = .ready
                    audioRecorder.startRecording(app: matchedApp)
                    // 一体化浮层：直接进入录制态。
                    FloatingLetterOverlayHost.shared.present(
                        appState: appState,
                        recorder: audioRecorder
                    )
                }
            } catch {
                await MainActor.run {
                    audioRecorder.error = "Failed to list apps: \(error.localizedDescription)"
                    self.presentRecordingFlowForURL()
                }
            }
        }
    }

    /// URL 流程进入一体化浮层的“选择应用”模式（替代旧 app-picker 窗口）。
    private func presentRecordingFlowForURL() {
        Task { @MainActor in
            guard let appState, let audioRecorder else { return }
            FloatingLetterOverlayHost.shared.startRecordingFlow(
                appState: appState,
                recorder: audioRecorder
            ) {
                FloatingLetterOverlayHost.shared.dismiss()
            }
        }
    }

    func processPendingURL() {
        if let url = pendingURL {
            pendingURL = nil
            handleURL(url)
        }
    }

    /// 退出闸：录制中必须先停录并 finalize 音频，否则 ⌘Q 会留下一个
    /// 未写 moov atom 的 .m4a（不可读）且实时转录文本随进程消失。
    /// `.terminateLater` 让我们异步完成收尾后再放行退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = audioRecorder, let appState else { return .terminateNow }
        guard recorder.state == .recording || recorder.state == .saving else {
            return .terminateNow
        }
        // 重复退出请求（连按 ⌘Q / 系统登出）不重复启动收尾流程。
        guard !isFinishingBeforeTerminate else { return .terminateLater }
        isFinishingBeforeTerminate = true

        Task { @MainActor in
            // finishRecording 内部：停实时识别 → 停录并写盘 → 落历史条目。
            await appState.finishRecording(recorder: recorder)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
        // 日志批量写出（异步 flush 最多滞后 0.3s，退出前补齐防丢尾）。
        AppLogger.shared.flushNow()
    }
}
