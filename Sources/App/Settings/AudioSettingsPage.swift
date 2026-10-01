import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Network

// MARK: - 音频

/// 音频设置：只做「可操作的事」。
///
/// 简洁化：原先本页有「麦克风权限行 + 重新检测按钮 + 当前输入状态整节
/// （录制状态/音频来源/录制应用）」，与系统状态页的权限区、当前识别行
/// 完全重复。现在权限与运行时状态统一由 系统状态 › 权限 / 当前识别 提供，
/// 本页只留屏幕录制的拖拽授权引导（它是操作入口，不是状态复述）
/// 与一个录制开关。
struct AudioSettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var screenCaptureMonitor = ScreenCaptureMonitor.shared

    var body: some View {
        @Bindable var audio = settings.audio

        Form {
            Section(header: IconSectionHeader("输入权限", icon: "mic.badge.xmark", color: .mint)) {
                // 屏幕捕获：拖拽式授权引导卡（状态徽标随授权变化）——引导入口
                // 常驻可见，拖拽体验不必先去系统设置移除授权才能看到。
                PermissionDragGuide(
                    permissionName: "屏幕录制",
                    settingsURL: URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!,
                    isGranted: screenCaptureMonitor.screenCaptureGranted,
                    onRecheck: { screenCaptureMonitor.requestAccess() }
                )
                if !screenCaptureMonitor.microphoneGranted {
                    SettingsHint(text: "麦克风未授权：录制只能拿到系统音频，收录不到你的声音。",
                                 level: .warning)
                }
            }

            Section(header: IconSectionHeader("录制", icon: "record.circle", color: .red)) {
                Toggle(isOn: $audio.defaultIncludeMicrophone) {
                    RowLabel(title: "默认包含麦克风",
                             detail: "录制系统音频时默认同时收录；浮层内可临时切换")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            screenCaptureMonitor.refresh()
            // 进音频页时若未授权：主动请求一次（触发系统弹窗）。
            // 系统只弹一次，之后静默——引导卡的「打开系统设置」为兜底。
            if !screenCaptureMonitor.screenCaptureGranted {
                screenCaptureMonitor.requestAccess()
            }
        }
    }
}
