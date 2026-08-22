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
        Window("WhisperASR", id: "main") {
            ContentView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.audioRecorder = audioRecorder
                    appDelegate.openWindow = openWindow
                    appDelegate.processPendingURL()
                    // 菜单栏快捷控制：必须在注入完成后 setup（此前触发时
                    // appState/audioRecorder 还是 nil → 状态项不出现）。
                    MenuBarController.shared.setup(appState: appState, audioRecorder: audioRecorder)
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
            CommandMenu("调试") {
                // 仅用于预览字幕浮层样式，不控制浮层启停。
                Button("字幕浮层样式预览…") {
                    openWindow(id: "debug-subtitle")
                }
#if DEBUG
                Button("浮层内存自检") {
                    FloatingLetterLeakTest.runAfterLaunch(appDelegate: appDelegate)
                }
#endif
            }
        }

        Window("Meeting Minutes", id: "minutes") {
            MinutesWindowView()
                .environment(appState)
        }
        .defaultSize(width: 720, height: 820)

        // Debug-only subtitle preview: manual text input → subtitle rendering.
        // Remove with Sources/DebugSubtitleView.swift and the "调试" menu above.
        Window("字幕浮层调试", id: "debug-subtitle") {
            DebugSubtitleView()
        }
        .defaultSize(width: 540, height: 400)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var audioRecorder: AudioRecorder?
    var openWindow: OpenWindowAction?
    var launchedViaURL = false
    private var pendingURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let icon = AppIconGenerator.generate()
        NSApplication.shared.applicationIconImage = icon
        let imageView = NSImageView(image: icon)
        NSApplication.shared.dockTile.contentView = imageView
        NSApplication.shared.dockTile.display()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
#if DEBUG
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
        guard let url = urls.first, url.scheme == "whisperasr" else { return }
        launchedViaURL = true
        // If the app state is ready, handle immediately; otherwise queue it
        // (audioRecorder is injected by the main window's onAppear).
        if audioRecorder != nil {
            handleURL(url)
        } else {
            pendingURL = url
        }
    }

    func handleURL(_ url: URL) {
        guard url.scheme == "whisperasr", url.host == "record",
              let audioRecorder else { return }

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

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
        // 日志批量写出（异步 flush 最多滞后 0.3s，退出前补齐防丢尾）。
        AppLogger.shared.flushNow()
    }
}
