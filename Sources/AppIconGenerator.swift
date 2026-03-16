import AppKit

enum AppIconGenerator {
    static func generate() -> NSImage {
        let size: CGFloat = 512
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)

        // Rounded rect clip (macOS icon shape)
        let cornerRadius: CGFloat = size * 0.22
        let path = CGPath(roundedRect: rect.insetBy(dx: 4, dy: 4),
                          cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                          transform: nil)
        ctx.addPath(path)
        ctx.clip()

        // Background gradient: deep teal to dark blue
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradientColors = [
            CGColor(red: 0.08, green: 0.75, blue: 0.72, alpha: 1.0),  // teal
            CGColor(red: 0.10, green: 0.30, blue: 0.65, alpha: 1.0),  // deep blue
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                  start: CGPoint(x: 0, y: size),
                                  end: CGPoint(x: size, y: 0),
                                  options: [])
        }

        // Draw sound waveform bars (centered)
        let barHeights: [CGFloat] = [0.12, 0.25, 0.42, 0.65, 0.85, 0.65, 0.42, 0.25, 0.12]
        let barWidth: CGFloat = size * 0.05
        let barSpacing: CGFloat = size * 0.025
        let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barSpacing
        let startX = (size - totalWidth) / 2
        let centerY = size * 0.52

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
        for (i, heightFrac) in barHeights.enumerated() {
            let barH = size * 0.55 * heightFrac
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = centerY - barH / 2
            let barRect = CGRect(x: x, y: y, width: barWidth, height: barH)
            let barPath = CGPath(roundedRect: barRect,
                                 cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
                                 transform: nil)
            ctx.addPath(barPath)
            ctx.fillPath()
        }

        // Draw small "ASR" text at bottom
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.08, weight: .bold),
            .foregroundColor: NSColor(white: 1, alpha: 0.7)
        ]
        let text = NSAttributedString(string: "ASR", attributes: attrs)
        let textSize = text.size()
        let textOrigin = NSPoint(x: (size - textSize.width) / 2, y: size * 0.12)
        text.draw(at: textOrigin)

        image.unlockFocus()
        return image
    }
}
