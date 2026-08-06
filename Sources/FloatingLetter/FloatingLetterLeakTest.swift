import Foundation
import AppKit

#if DEBUG

// MARK: - 一体化浮层内存自检
//
// 通过 DEBUG 存活计数验证 present/dismiss 后没有任何对象泄漏：
//   FloatingLetterViewModel   —— UI 状态 + 倒计时 Timer
//   FloatingLetterOverlayBinder —— 业务桥接（持有 VM / AppState / AudioRecorder）
//   FloatingLetterHostingView —— NSHostingView 容器
//
// 运行方式（命令行直接启动 App，结束后自动退出并输出 PASS/FAIL）：
//   WhisperASR.app/Contents/MacOS/WhisperASR --overlay-leak-test

/// 存活计数（仅 DEBUG 构建编译；release 构建中不产生任何代码）。
enum FloatingLetterLeakState {
    static var viewModelAlive = 0
    static var binderAlive = 0
    static var hostingViewAlive = 0
}

@MainActor
enum FloatingLetterLeakTest {
    /// `appDelegate` 为我们的 AppDelegate 实例。注意：在 @NSApplicationDelegateAdaptor
    /// 下 NSApp.delegate 是 SwiftUI 内部包装对象，不能通过它拿业务状态。
    static func runAfterLaunch(appDelegate: AppDelegate) {
        Task { @MainActor in
            // 等待主窗口 onAppear 完成 appState / audioRecorder 注入
            // （首次启动可能较慢，轮询最多 10 秒）。
            var appState: AppState?
            var recorder: AudioRecorder?
            for _ in 0..<40 {
                if let state = appDelegate.appState,
                   let audio = appDelegate.audioRecorder {
                    appState = state
                    recorder = audio
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }

            guard let appState, let recorder else {
                print("[LeakTest] FAIL: 未就绪")
                print("[LeakTest] FAIL: windows=\(NSApplication.shared.windows.map { $0.title })")
                print("[LeakTest] FAIL: appState=\(String(describing: appDelegate.appState)) recorder=\(String(describing: appDelegate.audioRecorder))")
                exit(1)
            }

            // 1. 宿主完整链路（VM + Binder + Controller + 窗口）：5 轮 present/dismiss。
            for round in 1...5 {
                FloatingLetterOverlayHost.shared.present(
                    appState: appState,
                    recorder: recorder
                )
                try? await Task.sleep(for: .milliseconds(250))
                FloatingLetterOverlayHost.shared.dismiss()
                try? await Task.sleep(for: .milliseconds(150))
                print("[LeakTest] round \(round) done")
            }

            // 2. 控制器 + 裸 ViewModel 链路（不经宿主）：3 轮。
            for round in 1...3 {
                let viewModel = FloatingLetterViewModel()
                FloatingLetterOverlayController.shared.present(viewModel: viewModel)
                try? await Task.sleep(for: .milliseconds(200))
                FloatingLetterOverlayController.shared.dismiss()
                try? await Task.sleep(for: .milliseconds(100))
                print("[LeakTest] bare round \(round) done")
            }

            // 3. 留出 deinit 收敛时间，然后断言存活计数全部归零。
            try? await Task.sleep(for: .milliseconds(800))
            let viewModelAlive = FloatingLetterLeakState.viewModelAlive
            let binderAlive = FloatingLetterLeakState.binderAlive
            let hostingViewAlive = FloatingLetterLeakState.hostingViewAlive
            print("[LeakTest] alive -> viewModel=\(viewModelAlive) binder=\(binderAlive) hostingView=\(hostingViewAlive)")

            if viewModelAlive == 0, binderAlive == 0, hostingViewAlive == 0 {
                print("[LeakTest] PASS")
                exit(0)
            } else {
                print("[LeakTest] FAIL")
                exit(1)
            }
        }
    }

    /// 录制驱动自检：模拟“点击开始录制”后 RecordingView 的挂载链路，
    /// 断言一体化浮层自动显示；关闭后隐藏。命令行：--overlay-replace-test。
    static func runReplaceTest(appDelegate: AppDelegate) {
        Task { @MainActor in
            var appState: AppState?
            var recorder: AudioRecorder?
            for _ in 0..<40 {
                if let state = appDelegate.appState,
                   let audio = appDelegate.audioRecorder {
                    appState = state
                    recorder = audio
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }

            guard let appState, let recorder else {
                print("[ReplaceTest] FAIL: appState / audioRecorder 未就绪")
                exit(1)
            }

            // RecordingView.onAppear 同款调用：点击“开始录制”后自动展示一体化浮层。
            FloatingLetterOverlayHost.shared.present(
                appState: appState,
                recorder: recorder
            )
            try? await Task.sleep(for: .milliseconds(600))

            let shown = FloatingLetterOverlayHost.shared.isPresented
            print("[ReplaceTest] 开始录制后 unifiedOverlayVisible=\(shown)")

            // 录制窗口关闭（onDisappear）→ 浮层隐藏。
            FloatingLetterOverlayHost.shared.dismiss()
            try? await Task.sleep(for: .milliseconds(300))
            let hidden = !FloatingLetterOverlayHost.shared.isPresented
            print("[ReplaceTest] 关闭录制窗口后 unifiedOverlayVisible=\(!hidden)")

            if shown, hidden {
                print("[ReplaceTest] PASS：录制开始自动显示，窗口关闭自动隐藏")
                exit(0)
            } else {
                print("[ReplaceTest] FAIL")
                exit(1)
            }
        }
    }
}

#endif
