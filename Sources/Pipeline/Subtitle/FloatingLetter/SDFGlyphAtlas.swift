import Foundation
import CoreText
import CoreGraphics
import Metal

// MARK: - SDF 字形图集生成（CPU 离线，文本变化时按需重建）
//
// 管线：字符 → CoreText path 栅格化（8bit 灰度覆盖）→ 精确欧氏距离变换
// → 有符号距离场归一化（0.5 = 字形边缘）→ shelf 打包进 2 的幂图集。
//
// 算法出处（移植公式，不引第三方依赖）：
// - 距离变换：P. Felzenszwalb & D. Huttenlocher, "Distance Transforms of
//   Sampled Functions" (Theory of Computing, 2012) 的 1D 下包络两遍法；
// - SDF 文本用法：libgdx DistanceFieldGenerator 与 Chlumsky/msdf-atlas
//   的经典单通道 SDF 方案（signed = d_outside − d_inside，0.5 等值线）。
//
// 约定：
// - 图集像素行 0 = 顶部（Metal v=0 在顶部），与 layer 的 y 向下坐标一致；
// - entry.uvRect 为**去除 padding 后的内部区域**（字形 ink 边界即 0.5
//   等值线），排版 quad 的 UV 映射到内部区域——边缘外 ±falloff px 的
//   距离信息用于平滑抗锯齿与外发光余量。
//
// 线程：纯 CPU 纯函数式，线程安全（调用方在文本变化时串行调用）。

// MARK: 距离变换

enum SDFDistanceTransform {

    /// Felzenszwalb 1D 精确平方欧氏距离变换（下包络法，O(n)）。
    /// 注意：源点标记用大有限数（非 .infinity）——∞−∞ = NaN 会破坏
    /// 抛物线交点计算（经典实现陷阱）。
    static func squaredDistance1D(_ f: [Double]) -> [Double] {
        let n = f.count
        guard n > 0 else { return [] }
        let inf = 1e20   // 大有限数代替无穷
        var d = [Double](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0
        z[0] = -inf
        z[1] = inf
        for q in 1..<n {
            var s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k])))
                / Double(2 * q - 2 * v[k])
            while s <= z[k] {
                k -= 1
                s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k])))
                    / Double(2 * q - 2 * v[k])
            }
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = inf
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            let dx = Double(q - v[k])
            d[q] = dx * dx + f[v[k]]
        }
        return d
    }

    /// 2D 距离场：到最近 `value` 像素的欧氏距离（行+列两遍 1D）。
    static func distance(toValue value: Bool, mask: [Bool], width: Int, height: Int) -> [Float] {
        let inf = 1e20
        var g = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            var row = [Double](repeating: 0, count: width)
            for x in 0..<width {
                row[x] = mask[y * width + x] == value ? 0 : inf
            }
            let d = squaredDistance1D(row)
            for x in 0..<width { g[y * width + x] = d[x] }
        }
        var out = [Float](repeating: 0, count: width * height)
        for x in 0..<width {
            var col = [Double](repeating: 0, count: height)
            for y in 0..<height { col[y] = g[y * width + x] }
            let d = squaredDistance1D(col)
            for y in 0..<height { out[y * width + x] = Float(d[y].squareRoot()) }
        }
        return out
    }
}

// MARK: 图集

/// 图集内单个字形的条目。
struct SDFAtlasEntry: Equatable {
    /// cell 在图集中的像素矩形（左上原点，行 0 = 顶部）。
    let cellRect: CGRect
    /// 归一化 UV：去除 padding 后的内部区域（ink 边界 = 0.5 等值线）。
    let uvRect: CGRect
}

/// SDF 字形图集（CPU 像素 + 可选 GPU 纹理）。
final class SDFGlyphAtlas {
    let width: Int
    let height: Int
    /// r8 单通道像素（行 0 = 顶部）。
    let pixels: [UInt8]
    /// key = 字符（String 形式，含代理对）。
    let entries: [String: SDFAtlasEntry]
    /// 栅格化字号（排版字号无关——SDF 分辨率无关，仅影响边缘精度）。
    let rasterFontSize: CGFloat

    init(width: Int, height: Int, pixels: [UInt8],
         entries: [String: SDFAtlasEntry], rasterFontSize: CGFloat) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.entries = entries
        self.rasterFontSize = rasterFontSize
    }

    /// 上传为 r8Unorm 采样纹理。
    func makeTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: width)
        }
        return texture
    }
}

// MARK: 生成器

/// 栅格化 cell（含 padding；行 0 = 顶部）。
private struct SDFCell {
    let key: String
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

enum SDFGlyphAtlasGenerator {

    /// 为 `text` 中出现的全部字符生成 SDF 图集。
    /// - Parameters:
    ///   - font: 栅格化字体（应与排版字体同族同 weight；字号无关——
    ///     实际按 rasterFontSize 复制缩放，SDF 分辨率与排版字号解耦）。
    ///   - falloffPx: SDF 有效衰减半径（图集像素；决定平滑与描边余量）。
    static func generate(text: String, font: CTFont,
                         falloffPx: Float = 6,
                         rasterFontSize: CGFloat = 96) -> SDFGlyphAtlas {
        // 关键：栅格化字号由 rasterFontSize 决定（默认 96pt）——若直接用
        // 排版字体（17pt），falloff 6px 会吃进字形内部，边缘质量崩坏。
        let rasterFont = CTFontCreateCopyWithAttributes(font, rasterFontSize, nil, nil)
        // 去重字符（含代理对聚合成单 key）。
        var uniqueKeys: [String] = []
        var seen = Set<String>()
        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            var key = String(decoding: utf16[i...i], as: UTF16.self)
            if UTF16.isLeadSurrogate(utf16[i]), i + 1 < utf16.count {
                key = String(decoding: utf16[i...i + 1], as: UTF16.self)
                i += 1
            }
            if !seen.contains(key) {
                seen.insert(key)
                uniqueKeys.append(key)
            }
            i += 1
        }

        // 栅格化 + SDF：逐字符产出 cell（含 padding）。
        let pad = Int(falloffPx) + 2
        var cells: [SDFCell] = []
        for key in uniqueKeys {
            guard let cell = rasterize(key: key, font: rasterFont,
                                       falloffPx: falloffPx, pad: pad,
                                       rasterFontSize: rasterFontSize) else {
                continue   // 空白字符/无 ink：排版侧零宽处理，不入图集
            }
            cells.append(cell)
        }

        // Shelf 打包：按高降序塞行，图集宽高取 2 的幂。
        // 初始尺寸必须容纳最大 cell（96pt 中文字形 cell 可达 ~112px 宽，
        // 小于 cell 宽的图集行会横向越界与相邻字形重叠）。
        cells.sort { $0.height > $1.height }
        func nextPow2(_ v: Int) -> Int {
            var p = 1
            while p < v { p <<= 1 }
            return p
        }
        let maxCellWidth = cells.map(\.width).max() ?? 0
        let maxCellHeight = cells.map(\.height).max() ?? 0
        var atlasWidth = nextPow2(max(64, maxCellWidth))
        var placed: [(SDFCell, CGRect)] = []
        var atlasHeight = nextPow2(max(64, maxCellHeight))
        while true {
            placed = []
            var x = 0, y = 0, rowHeight = 0
            var overflow = false
            for cell in cells {
                if x + cell.width > atlasWidth {
                    x = 0
                    y += rowHeight
                    rowHeight = 0
                }
                if y + cell.height > atlasHeight { overflow = true; break }
                placed.append((cell, CGRect(x: x, y: y, width: cell.width, height: cell.height)))
                x += cell.width
                rowHeight = max(rowHeight, cell.height)
            }
            if !overflow { break }
            atlasWidth *= 2
            atlasHeight *= 2
        }

        // 合成像素（行 0 = 顶部；cell 自身行 0 已是顶部）。
        var pixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        var entries: [String: SDFAtlasEntry] = [:]
        for (cell, rect) in placed {
            for row in 0..<cell.height {
                let src = row * cell.width
                let dst = (Int(rect.minY) + row) * atlasWidth + Int(rect.minX)
                pixels.replaceSubrange(dst..<(dst + cell.width),
                                       with: cell.pixels[src..<(src + cell.width)])
            }
            // 内部 UV（去 padding；边缘 = ink 边界）。
            let innerX = (rect.minX + CGFloat(pad)) / CGFloat(atlasWidth)
            let innerY = (rect.minY + CGFloat(pad)) / CGFloat(atlasHeight)
            let innerW = (rect.width - CGFloat(2 * pad)) / CGFloat(atlasWidth)
            let innerH = (rect.height - CGFloat(2 * pad)) / CGFloat(atlasHeight)
            entries[cell.key] = SDFAtlasEntry(
                cellRect: rect,
                uvRect: CGRect(x: innerX, y: innerY, width: innerW, height: innerH))
        }

        return SDFGlyphAtlas(width: atlasWidth, height: atlasHeight,
                             pixels: pixels, entries: entries,
                             rasterFontSize: rasterFontSize)
    }

    /// 单字符栅格化 → 有符号距离场（0.5 = ink 边界，行 0 = 顶部）。
    private static func rasterize(key: String, font: CTFont,
                                  falloffPx: Float, pad: Int,
                                  rasterFontSize: CGFloat) -> SDFCell? {
        // 字形解析 + 字体回退（系统字体无 CJK → CTFontCreateForString 挑后备字体）。
        guard let (glyphFont, glyph) = resolveGlyph(key: key, baseFont: font),
              let path = CTFontCreatePathForGlyph(glyphFont, glyph, nil) else {
            return nil
        }
        let bbox = path.boundingBoxOfPath
        guard bbox.width > 0.5, bbox.height > 0.5 else { return nil }   // 空白字形

        let width = Int(bbox.width.rounded(.up)) + 2 * pad
        let height = Int(bbox.height.rounded(.up)) + 2 * pad
        guard width > 0, height > 0, width < 2048, height < 2048 else { return nil }

        // 8bit 灰度位图（CG 坐标 y 向上），路径平移到 cell 内。
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.translateBy(x: -bbox.minX + CGFloat(pad), y: -bbox.minY + CGFloat(pad))
        context.addPath(path)
        context.fillPath()

        guard let data = context.data else { return nil }
        let raw = data.bindMemory(to: UInt8.self, capacity: width * height)
        let coverage = Array(UnsafeBufferPointer(start: raw, count: width * height))

        // 覆盖 → 二值 → 双向距离场 → SDF（0.5 等值线 = ink 边界）。
        var mask = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) { mask[i] = coverage[i] >= 128 }
        let dIn = SDFDistanceTransform.distance(toValue: true, mask: mask,
                                                width: width, height: height)
        let dOut = SDFDistanceTransform.distance(toValue: false, mask: mask,
                                                 width: width, height: height)
        var sdf = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let signed = Float(dIn[i]) - Float(dOut[i])   // 外正内负，边缘 0
            let value = 0.5 - signed / (2 * falloffPx)
            sdf[i] = UInt8(max(0, min(255, value * 255)))
        }
        // CG 位图行 0 = 底部（y 向上）→ 翻转为图集约定（行 0 = 顶部）。
        var flipped = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            flipped.replaceSubrange(row * width..<(row + 1) * width,
                                    with: sdf[(height - 1 - row) * width..<(height - row) * width])
        }
        return SDFCell(key: key, width: width, height: height, pixels: flipped)
    }

    /// 字符 → (实际字体, glyph)：主字体命中优先，否则 CoreText 字体回退。
    static func resolveGlyph(key: String, baseFont: CTFont) -> (CTFont, CGGlyph)? {
        let unichars = Array(key.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        if CTFontGetGlyphsForCharacters(baseFont, unichars, &glyphs, unichars.count),
           glyphs[0] != 0 {
            return (baseFont, glyphs[0])
        }
        // 后备字体（CJK 等）：按字符串自动挑选可绘制的字体。
        let fallback = CTFontCreateForString(baseFont, key as CFString,
                                             CFRange(location: 0, length: unichars.count))
        if CTFontGetGlyphsForCharacters(fallback, unichars, &glyphs, unichars.count),
           glyphs[0] != 0 {
            return (fallback, glyphs[0])
        }
        return nil
    }
}
