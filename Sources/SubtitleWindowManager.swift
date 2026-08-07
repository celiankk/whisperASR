import AppKit
import Foundation

// MARK: - 字幕窗口状态管理（SubtitleWindowManager）
//
// 统一管理 FloatingSubtitleWindow 的窗口状态，禁止多个 View 分别修改 window：
// - windowFrame：记录 currentFrame（不因模式切换重新计算）；
// - windowMode：interactive（唯一默认：可移动、左上角缩放）/ passthrough；
// - mouseInteraction：passthrough / active；
// - editState：resize 拖拽会话（左上角、起始 frame、起始点）。

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

    enum ResizeEdge: Equatable {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight

        var containsLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        var containsRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        var containsTop: Bool { self == .top || self == .topLeft || self == .topRight }
        var containsBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }

    private(set) var mode: SubtitleWindowMode = .interactive
    private(set) var mouseInteraction: MouseInteraction = .active

    var isPassthrough: Bool { mode == .passthrough }

    private(set) var currentFrame: NSRect?

    /// 当前 resize 拖拽会话（nil = 未拖拽中）。
    private(set) var resizeSession: (edge: ResizeEdge, startFrame: NSRect, startPoint: NSPoint)?

    var isResizing: Bool { resizeSession != nil }

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

    func beginResize(edge: ResizeEdge, startFrame: NSRect, startPoint: NSPoint) {
        resizeSession = (edge: edge, startFrame: startFrame, startPoint: startPoint)
    }

    /// 根据拖拽增量计算新窗口帧（原生 NSWindow resize，不做 SwiftUI 模拟）。
    func resizedFrame(deltaX: CGFloat, deltaY: CGFloat, minSize: NSSize, maxSize: NSSize) -> NSRect? {
        guard let session = resizeSession else { return nil }
        let edge = session.edge
        let isCorner = edge == .topLeft || edge == .topRight
            || edge == .bottomLeft || edge == .bottomRight

        // 用本地 CGFloat 显式计算（避免对 NSRect 链式属性算术的异常）。
        var newX = session.startFrame.origin.x
        var newY = session.startFrame.origin.y
        var newWidth = session.startFrame.size.width
        var newHeight = session.startFrame.size.height

        // 左/右边缘：宽度跟随指针；左缘同步移动原点（右锚点固定）。
        if edge.containsRight {
            newWidth += deltaX
        }
        if edge.containsLeft {
            newX += deltaX
            newWidth -= deltaX
        }
        // 上/下边缘：高度跟随指针；纯下缘同步移动原点（上锚点固定）。
        if edge.containsTop {
            newHeight += deltaY
        }
        if edge.containsBottom {
            if isCorner {
                newHeight += deltaY
            } else {
                newY += deltaY
                newHeight -= deltaY
            }
        }
        // 钳制到最小/最大尺寸（防止无限扩张/反向拖爆）。
        let width = min(max(newWidth, minSize.width), maxSize.width)
        let height = min(max(newHeight, minSize.height), maxSize.height)
        // 钳制后保持锚点：左缘保持右锚点，纯下缘保持上锚点。
        if edge.containsLeft {
            newX = session.startFrame.maxX - width
        }
        if edge.containsBottom, !isCorner {
            newY = session.startFrame.maxY - height
        }
        return NSRect(x: newX, y: newY, width: width, height: height)
    }

    func endResize() {
        resizeSession = nil
    }

    func reset() {
        mode = .interactive
        mouseInteraction = .passthrough
        currentFrame = nil
        resizeSession = nil
    }
}
