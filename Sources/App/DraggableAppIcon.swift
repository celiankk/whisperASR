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
        let pasteboardItem = NSPasteboardItem()
        // file URL 双写：标准 UTType + 兼容字符串路径（系统设置任一形态都认）。
        if let data = try? JSONEncoder().encode(fileURL) {
            pasteboardItem.setData(data, forType: .fileURL)
        }
        pasteboardItem.setString(fileURL.path, forType: .fileURL)
        pasteboardItem.setString(fileURL.path, forType: .string)

        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let iconSize = NSSize(width: 48, height: 48)
        dragItem.setDraggingFrame(NSRect(origin: .zero, size: iconSize), contents: icon)

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
