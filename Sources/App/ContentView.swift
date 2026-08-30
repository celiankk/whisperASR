import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioPlayerManager.self) var audioPlayer
    @Environment(AudioRecorder.self) var recorder
    @State private var showModelDownload = false

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            if appState.showingSettingsPage {
                // 主窗口内嵌设置页：工具栏设置按钮在主窗口内部切换，
                // 不新建窗口；录制状态在切换期间保持（recorder 由 App 级持有）。
                SettingsView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                } detail: {
                    DetailView()
                }
            }

            if !appState.showingSettingsPage, appState.selectedItem?.status == .completed {
                Divider()
                PlayerView()
            }
        }
        .toolbar {
            // 设置页显式「返回转录」按钮（主窗口内嵌设置页时显示，
            // 与右上角设置按钮等效，返回主界面）。
            ToolbarItem(placement: .navigation) {
                if appState.showingSettingsPage {
                    Button {
                        appState.showingSettingsPage = false
                    } label: {
                        Label(L10n.t("common.back"), systemImage: "chevron.backward")
                    }
                    .help(L10n.t("common.back"))
                }
            }
            // 顶部工具栏右侧同一区域：设置 + 录制。
            ToolbarItemGroup(placement: .primaryAction) {
                // 设置：主窗口内部切换 SettingsView（不新建窗口），再次点击返回。
                Button {
                    appState.showingSettingsPage.toggle()
                } label: {
                    Label("设置", systemImage: appState.showingSettingsPage
                          ? "gearshape.fill" : "gearshape")
                }
                .help(appState.showingSettingsPage ? "返回主界面" : "设置")

                // 录制：Toolbar 只展示状态并触发一体化浮层流程，
                // 开始/停止与音频输入逻辑仍由 AudioRecorder 管理。
                if recorder.state == .recording || recorder.state == .saving {
                    Button {
                        // 录制中点击只确保一体化浮层可见（停止在浮层内操作）。
                        FloatingLetterOverlayHost.shared.present(
                            appState: appState,
                            recorder: recorder
                        )
                    } label: {
                        Label("录制中", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        // 录制入口授权闸：未授权时点录制直接跳授权
                        //（系统弹窗 + 悬浮授权窗附着系统设置 + 打开录屏面板），
                        // 不进应用选择流程。
                        guard PermissionGuidePanelController.shared.authorizeForRecording() else {
                            return
                        }
                        // 一体化浮层：点击"录制"后浮层内选择应用并开始录制。
                        FloatingLetterOverlayHost.shared.startRecordingFlow(
                            appState: appState,
                            recorder: recorder
                        ) {
                            // 取消/结束录制：收起浮层。
                            FloatingLetterOverlayHost.shared.dismiss()
                        }
                    } label: {
                        Label("录制", systemImage: "record.circle")
                    }
                }
            }
        }
        .toast(message: $appState.transientToast)
        .sheet(isPresented: $showModelDownload) {
            ModelDownloadView(isPresented: $showModelDownload)
        }
        .onAppear {
            if !TranscriptionService.modelExists() {
                showModelDownload = true
            }
        }
        // 录制状态监听挂在外层（设置页切换会卸载 SidebarView，不能放在那里）。
        .onChange(of: recorder.state) { old, new in
            if new == .recording {
                let appState = appState
                let recorder = recorder
                recorder.onMeetingEnded = {
                    handleMeetingEnded(appState: appState, recorder: recorder)
                }
            } else if old == .recording {
                recorder.onMeetingEnded = nil
            }
        }
    }

    private func handleMeetingEnded(appState: AppState, recorder: AudioRecorder) {
        NSApp.requestUserAttention(.criticalRequest)

        let alert = NSAlert()
        alert.messageText = "会议已结束"
        alert.informativeText = "Zoom 会议似乎已结束。你想停止录制吗？"
        alert.addButton(withTitle: "停止录制")
        alert.addButton(withTitle: "继续录制")
        alert.alertStyle = .informational
        alert.icon = AppIconGenerator.generate()

        // Show the alert window above all other windows (including Zoom)
        let panel = alert.window
        panel.level = .screenSaver
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task {
                await appState.finishRecording(recorder: recorder)
                // 录制结束后收起一体化浮层。
                FloatingLetterOverlayHost.shared.dismiss()
            }
        }
    }
}
