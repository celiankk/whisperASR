import AppKit
import Foundation

// MARK: - 字幕窗口状态管理（SubtitleWindowManager）
//
// 统一管理 FloatingSubtitleWindow 的窗口状态，禁止多个 View 分别修改 window：
// - windowFrame：记录 currentFrame（不因模式切换重新计算）；
// - windowMode：interactive（唯一默认：可移动、左上角缩放）/ passthrough；
// - mouseInteraction：passthrough / active；
// - resize：系统原生（titled + fullSizeContentView + resizable），
//   无自制拖拽会话。

@MainActor
final class SubtitleWindowManager {
    enum SubtitleWindowMode: Equatable {
        /// 唯一默认模式：窗口始终可移动、可左上角缩放、显示可配置编辑边框。
        case interactive
        /// 鼠标穿透：只显示字幕，点击穿过。
        case passthrough
    }

    enum MouseInteraction: Equatable {
        case passthrough
        case active
    }

    private(set) var mode: SubtitleWindowMode = .interactive
    private(set) var mouseInteraction: MouseInteraction = .active

    var isPassthrough: Bool { mode == .passthrough }

    private(set) var currentFrame: NSRect?

    func markFrame(_ frame: NSRect) {
        // 只记录帧：窗口移动/缩放通知不应污染鼠标交互状态
        //（穿透模式下窗口被程序移动也曾把 mouseInteraction 误翻为 active）。
        currentFrame = frame
    }

    func setPassthrough(_ enabled: Bool) {
        if enabled {
            mode = .passthrough
            mouseInteraction = .passthrough
        } else {
            mode = .interactive
            mouseInteraction = .active
        }
    }

    func reset() {
        mode = .interactive
        mouseInteraction = .passthrough
        currentFrame = nil
    }
}
