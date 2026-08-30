import Foundation
import Observation
import AVFoundation
import CoreGraphics
import AppKit

// MARK: - 屏幕捕获 / 麦克风状态检测（ScreenCaptureMonitor）
//
// 检测 macOS 屏幕录制权限、麦克风权限与捕获源进程生命周期。
// 录制期间 AppState 健康检查用它判断“屏幕共享软件是否被关闭”，
// 一旦源消失自动结束录制并释放全部资源（Audio / ASR / 字幕 / Task）。

@Observable
final class ScreenCaptureMonitor {
    static let shared = ScreenCaptureMonitor()

    private(set) var screenCaptureGranted = false
    private(set) var microphoneGranted = false

    private init() {
        refresh()
    }

    func refresh() {
        // 屏幕录制权限（CGPreflightScreenCaptureAccess，macOS 10.15+）。
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        // 麦克风权限。
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 主动请求屏幕录制授权（CGRequestScreenCaptureAccess）：
    /// 触发系统授权弹窗（「允许 WhisperASR 录制屏幕」）。注意系统只弹
    /// 一次——之后调用静默返回 false，用户需经系统设置（拖拽引导卡
    /// 的替代路径）；弹窗出现与否由系统决定，本方法总是刷新状态。
    func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    /// 指定应用进程是否仍在运行（用于屏幕共享/捕获源被关闭的检测）。
    func isProcessRunning(processIdentifier: pid_t?, bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let pid = processIdentifier {
            return running.contains { $0.processIdentifier == pid }
        }
        return !running.isEmpty
    }
}
