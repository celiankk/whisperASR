import AppKit

// MARK: - SonicScribe 图标生成（程序化几何风）
//
// 设计：青蓝对角渐变 squircle + 白色声波条（对称波包）+ 红色录音点。
// 输出 macOS iconset 全尺寸 PNG，经 iconutil 合成 .icns。
// 用法：swift Scripts/generate_icon.swift <iconset 目录>

let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let iconsetPath = CommandLine.arguments[1]

/// SonicScribe 图标：青蓝对角渐变 squircle + 白色声波条 + 红色录音点。
func generateIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    let s = size

    // 1. 背景 squircle（macOS 图标栅格：inset 10%、圆角 22%）并裁剪。
    let inset = s * 0.10
    let squircle = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = squircle.width * 0.22
    let clipPath = CGPath(roundedRect: squircle, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(clipPath)
    ctx.clip()

    // 2. 对角渐变背景（青 → 蓝紫，较上一版降饱和、更沉稳）。
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                   colors: [
                       CGColor(red: 0.16, green: 0.72, blue: 0.72, alpha: 1),
                       CGColor(red: 0.24, green: 0.32, blue: 0.74, alpha: 1),
                   ] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // 3. 声波条：5 根圆角竖条，对称高度（两端矮、中间高），白色。
    let barHeights: [CGFloat] = [0.30, 0.55, 1.00, 0.55, 0.30]
    let barWidth = s * 0.058
    let barGap = s * 0.044
    let waveWidth = CGFloat(barHeights.count) * barWidth
        + CGFloat(barHeights.count - 1) * barGap
    let dotDiameter = s * 0.075
    let dotGap = s * 0.060
    let totalWidth = waveWidth + dotGap + dotDiameter
    let startX = (s - totalWidth) / 2
    let centerY = s * 0.5
    let maxBarHeight = s * 0.46

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    for (i, hf) in barHeights.enumerated() {
        let barHeight = maxBarHeight * hf
        let x = startX + CGFloat(i) * (barWidth + barGap)
        let y = centerY - barHeight / 2
        let bar = CGPath(roundedRect: CGRect(x: x, y: y, width: barWidth, height: barHeight),
                         cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.addPath(bar)
        ctx.fillPath()
    }

    // 4. 录音点：波尾右侧的实心珊瑚红点（「正在收录」意象，无描边更简洁）。
    let dotX = startX + waveWidth + dotGap
    let dotRect = CGRect(x: dotX, y: centerY - dotDiameter / 2,
                         width: dotDiameter, height: dotDiameter)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.36, blue: 0.32, alpha: 1))
    ctx.fillEllipse(in: dotRect)

    image.unlockFocus()
    return image
}

let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let img = generateIcon(size: size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name).png"))
}
print("Iconset created at \(iconsetPath)")
