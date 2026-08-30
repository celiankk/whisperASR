import AppKit
import SwiftUI

// MARK: - 拖拽图标视图（DragIconAppView）
//
// AppKit 原生拖拽会话（beginDraggingSession + pasteboard file URL）：
// SwiftUI .onDrag 跨 app 拖进系统设置 TCC 列表不可靠（用户实测拖不动），
// Finder 同款 AppKit 路径是系统设置接受的标准形态。
// NSViewRepresentable 包装进 SwiftUI。

/// AppKit 拖拽源视图：mouseDown 即启动拖拽会话（图标整个可抓）。
final class AppIconDragSourceView: NSView, NSDraggingSource {
    let fileURL: URL
    private let icon: NSImage

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        // 完整镜像 Finder 拖 app 的 pasteboard 形态——系统设置 TCC 列表
        // 读的是 NSFilenamesPboardType（旧版文件名类型，路径数组的属性
        // 列表序列化），缺失它 = 拖起但放下无效果。
        let pasteboardItem = NSPasteboardItem()

        // 1. 标准 file URL（dataRepresentation = URL 字节串）。
        pasteboardItem.setData(fileURL.dataRepresentation, forType: .fileURL)

        // 2. 旧版文件名类型（系统设置 TCC 列表的实际读取源）。
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let plistData = try? PropertyListSerialization.data(
            fromPropertyList: [fileURL.path], format: .binary, options: 0) {
            pasteboardItem.setData(plistData, forType: filenamesType)
        }

        // 3. 纯文本路径（兜底）。
        pasteboardItem.setString(fileURL.path, forType: .string)

        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // 拖拽影像帧是【窗口坐标】：此前用 origin .zero（窗口左下角），
        // 拖拽影像出现在窗口角落、视觉上「拖不动」。
        dragItem.setDraggingFrame(convert(bounds, to: nil), contents: icon)

        // 非激活面板（悬浮授权窗）场景：app 不在前台时拖拽会话收不到
        // mouseDragged 事件——先激活自身（系统设置仍在屏上，只是失焦，
        // 拖入它的窗口照样接受放置）。
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor draggingContext: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds.insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.1))
    }
}

/// SwiftUI 包装：设置页引导卡与悬浮授权窗共用。
struct DraggableAppIcon: NSViewRepresentable {
    let fileURL: URL
    var iconSide: CGFloat = 48

    func makeNSView(context: Context) -> AppIconDragSourceView {
        let view = AppIconDragSourceView(fileURL: fileURL)
        view.toolTip = "按住我，拖到系统设置的列表里"
        return view
    }

    func updateNSView(_ nsView: AppIconDragSourceView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}
