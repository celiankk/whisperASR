import AppKit

// MARK: - 菜单栏图标（方案 A：声波柱 + 录音点）
//
// 设计语言取自 recent.design 的品牌规则：只用【实心质量 + 一个大圆角】，
// 不描边、不加白底板、不用渐变；右下圆点破开对称，同时兼任录制状态位。
// 母题与 app 图标（声波 + 录音点）同源，菜单栏与 Dock 看到的是同一个标志。
//
// 工程约束：
// • 18pt 画布，所有边界落在 0.5pt 网格上 → 1x 屏不糊、Retina 不毛；
// • 柱宽 2pt / 间隙 1.5pt：再细在菜单栏就会被抗锯齿吃成灰线；
// • 空闲态用 template（系统按深浅色菜单栏自动着色，菜单高亮时正确反色）；
// • 录制态用非 template：柱体走 labelColor（仍随外观自适应），
//   圆点走 systemRed —— 只有点变红，图形位置一像素都不动，
//   切换状态时菜单栏不会跳。

enum MenuBarIcon {

    /// 画布边长（= NSStatusItem 实际绘制尺寸）。
    static let canvas: CGFloat = 18

    private static let heights: [CGFloat] = [5, 10, 7, 12, 8]
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 1.5
    /// 柱组整体左移 1.5pt，给右下圆点让位（非对称构成）。
    private static let barGroupShift: CGFloat = -1.5

    /// 生成图标。
    /// - Parameter recording: 录制中（含保存中）→ 圆点转红并略放大。
    static func image(recording: Bool) -> NSImage {
        let size = NSSize(width: canvas, height: canvas)
        let image = NSImage(size: size, flipped: false) { _ in
            drawBars(color: recording ? NSColor.labelColor : NSColor.black)
            drawDot(recording: recording)
            return true
        }
        // 空闲走模板：菜单栏深浅色与菜单高亮都由系统处理。
        // 录制走非模板：需要保留圆点的系统红。
        image.isTemplate = !recording
        image.accessibilityDescription = "声记 SonicScribe"
        return image
    }

    // MARK: 绘制

    private static func drawBars(color: NSColor) {
        color.setFill()
        let groupWidth = CGFloat(heights.count) * barWidth
            + CGFloat(heights.count - 1) * barGap
        var x = (canvas - groupWidth) / 2 + barGroupShift
        let centerY = canvas / 2 + 1

        for height in heights {
            let rect = NSRect(x: quantize(x), y: quantize(centerY - height / 2),
                              width: barWidth, height: quantize(height))
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            x += barWidth + barGap
        }
    }

    private static func drawDot(recording: Bool) {
        if recording {
            NSColor.systemRed.setFill()
        } else {
            NSColor.black.setFill()
        }
        let diameter: CGFloat = recording ? 5.5 : 4.5
        let margin: CGFloat = 0.5
        let rect = NSRect(x: canvas - diameter - margin, y: margin,
                          width: diameter, height: diameter)
        NSBezierPath(ovalIn: rect).fill()
    }

    /// 对齐到 0.5pt 网格，避免半像素模糊。
    private static func quantize(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
