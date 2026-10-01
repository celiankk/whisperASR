import XCTest
import Metal
@testable import WhisperASR

// MARK: - SDF 图集 + 排版引擎 + 控制器测试
//
// 覆盖：Felzenszwalb 距离变换精确性、SDF 0.5 等值线语义、图集打包边界、
// CoreText 排版的词归属（拉丁/中文/折行）、控制器闭环（内容→图集→排版→GPU）。
@MainActor
final class MetalGlyphPipelineTests: XCTestCase {

    // MARK: 距离变换

    func testDistanceTransform1DExact() {
        // 单点源在位置 2：距离应严格 = |q - 2|（精确欧氏，非近似）。
        // 注意：非源点用大有限数 1e20（与实现约定一致；真 ∞ 会产生 NaN）。
        let f = [1e20, 1e20, 0.0, 1e20, 1e20, 1e20]
        let d = SDFDistanceTransform.squaredDistance1D(f)
        XCTAssertEqual(d.map { Float($0.squareRoot()) }, [2, 1, 0, 1, 2, 3])
    }

    func testDistanceTransform2DNearest() {
        // 8×8 网格，仅 (4, 4) 一个 true 像素：其余像素距离 = 欧氏距离。
        var mask = [Bool](repeating: false, count: 64)
        mask[4 * 8 + 4] = true
        let dist = SDFDistanceTransform.distance(toValue: true, mask: mask,
                                                 width: 8, height: 8)
        XCTAssertEqual(dist[4 * 8 + 4], 0, accuracy: 1e-4)
        XCTAssertEqual(dist[4 * 8 + 2], 2, accuracy: 1e-4)
        // 对角线 (2, 2)：欧氏 2√2 ≈ 2.828（曼哈顿近似会得 4——精确性证据）。
        XCTAssertEqual(dist[2 * 8 + 2], Float(2 * 2.0.squareRoot()), accuracy: 1e-3)
    }

    // MARK: 图集生成

    func testAtlasGenerationForSentence() throws {
        let font = NSFont.systemFont(ofSize: 24, weight: .medium)
        let atlas = SDFGlyphAtlasGenerator.generate(text: "你好 hi", font: font as CTFont)
        // 每个非空白字符都有条目（空白被跳过）。
        for key in ["你", "好", "h", "i"] {
            XCTAssertNotNil(atlas.entries[key], "missing entry for \(key)")
        }
        XCTAssertNil(atlas.entries[" "], "space must not occupy atlas cell")
        // 条目 UV 在 [0,1] 内且内部区域宽高为正。
        for (_, entry) in atlas.entries {
            XCTAssertTrue(entry.uvRect.minX >= 0 && entry.uvRect.maxX <= 1)
            XCTAssertTrue(entry.uvRect.minY >= 0 && entry.uvRect.maxY <= 1)
            XCTAssertGreaterThan(entry.uvRect.width, 0)
            XCTAssertGreaterThan(entry.uvRect.height, 0)
        }
        // GPU 纹理可创建。
        if let device = MTLCreateSystemDefaultDevice() {
            let texture = atlas.makeTexture(device: device)
            XCTAssertNotNil(texture)
            XCTAssertEqual(texture?.width, atlas.width)
            XCTAssertEqual(texture?.height, atlas.height)
        }
    }

    /// SDF 语义：字形 ink 中心 ≈ 1（完全内部），远离字形处 ≈ 0，边缘附近过渡。
    func testSDFValueSemantics() throws {
        let font = NSFont.systemFont(ofSize: 96, weight: .bold)
        let atlas = SDFGlyphAtlasGenerator.generate(text: "l", font: font as CTFont)
        let entry = try XCTUnwrap(atlas.entries["l"])
        // cellRect 内采样：中心（l 是竖条 → 水平中心在条内）≈ 1。
        let cx = Int(entry.cellRect.midX), cy = Int(entry.cellRect.midY)
        let center = atlas.pixels[cy * atlas.width + cx]
        XCTAssertGreaterThan(center, 220, "glyph interior must be near 1.0")

        // cell 左边缘 padding 带（远离 ink）≈ 0。
        let corner = atlas.pixels[Int(entry.cellRect.minY + 1) * atlas.width
                                  + Int(entry.cellRect.minX) + 1]
        XCTAssertLessThan(corner, 36, "far outside must be near 0.0")
    }

    // MARK: 排版与词归属

    private func makeAtlas(text: String, font: NSFont) -> SDFGlyphAtlas {
        SDFGlyphAtlasGenerator.generate(text: text, font: font as CTFont)
    }

    func testLayoutMapsWordsInOrder() throws {
        let font = NSFont.systemFont(ofSize: 24, weight: .medium)
        let text = "hello world foo"
        let words = [
            WordTimestamp(word: "hello", start: 0, end: 0.5),
            WordTimestamp(word: "world", start: 0.5, end: 1.0),
            WordTimestamp(word: "foo", start: 1.0, end: 1.4),
        ]
        let engine = SubtitleGlyphLayoutEngine(font: font)
        let result = engine.layout(text: text, width: 500,
                                   atlas: makeAtlas(text: text, font: font),
                                   wordTimestamps: words)
        XCTAssertGreaterThan(result.glyphs.count, 10)
        XCTAssertEqual(result.lineCount, 1, "500pt 宽足够单行")
        // 词索引全部落在 0..2，且三个词都有 glyph 归属。
        let indices = Set(result.glyphs.map(\.wordIndex))
        XCTAssertEqual(indices, [0, 1, 2])
        // 所有 glyph 在文本块内。
        for glyph in result.glyphs {
            XCTAssertGreaterThanOrEqual(glyph.rect.minX, -1)
            XCTAssertLessThanOrEqual(glyph.rect.maxX, 501)
        }
    }

    func testLayoutWrapsToMultipleLines() throws {
        let font = NSFont.systemFont(ofSize: 24, weight: .medium)
        let text = "hello world foo bar"
        let words = text.split(separator: " ").enumerated().map { i, w in
            WordTimestamp(word: String(w), start: Double(i), end: Double(i) + 0.4)
        }
        let engine = SubtitleGlyphLayoutEngine(font: font)
        let result = engine.layout(text: text, width: 80,
                                   atlas: makeAtlas(text: text, font: font),
                                   wordTimestamps: words)
        XCTAssertGreaterThanOrEqual(result.lineCount, 2, "80pt 宽必然折行")
        // 折行后 glyph 的 y 分布跨越多行。
        let ys = Set(result.glyphs.map { Int($0.rect.minY / 10) })
        XCTAssertGreaterThanOrEqual(ys.count, 2)
    }

    func testLayoutChineseWordMapping() throws {
        let font = NSFont.systemFont(ofSize: 24, weight: .medium)
        let text = "你好世界"
        let words = [
            WordTimestamp(word: "你好", start: 0, end: 0.6),
            WordTimestamp(word: "世界", start: 0.6, end: 1.2),
        ]
        let engine = SubtitleGlyphLayoutEngine(font: font)
        let result = engine.layout(text: text, width: 400,
                                   atlas: makeAtlas(text: text, font: font),
                                   wordTimestamps: words)
        XCTAssertEqual(result.glyphs.count, 4)
        // 词归属：分词「你好」/「世界」→ 前两字词 0、后两字词 1。
        let sorted = result.glyphs.sorted { $0.rect.minX < $1.rect.minX }
        XCTAssertEqual(sorted[0].wordIndex, 0)
        XCTAssertEqual(sorted[2].wordIndex, 1)
    }

    // MARK: 进度折算（外部时钟桥）

    func testProgressAtTimeMapping() {
        let words = [
            WordTimestamp(word: "a", start: 0.0, end: 1.0),
            WordTimestamp(word: "b", start: 2.0, end: 3.0),
        ]
        XCTAssertEqual(SubtitleGlyphLayoutEngine.progress(at: -1, words: words), 0)
        XCTAssertEqual(SubtitleGlyphLayoutEngine.progress(at: 0.5, words: words), 0.5)
        XCTAssertEqual(SubtitleGlyphLayoutEngine.progress(at: 1.5, words: words), 1)   // 间隙
        XCTAssertEqual(SubtitleGlyphLayoutEngine.progress(at: 2.5, words: words), 1.5)
        XCTAssertEqual(SubtitleGlyphLayoutEngine.progress(at: 99, words: words), 2)
    }

    // MARK: 控制器闭环（图集 → 排版 → GPU quad）

    func testControllerSetContentProducesGPUQuads() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device")
        }
        let controller = try MetalSubtitleController()
        let words = [
            WordTimestamp(word: "hello", start: 0, end: 0.5),
            WordTimestamp(word: "world", start: 0.5, end: 1.0),
        ]
        try controller.setContent(text: "hello world", words: words,
                                  viewportSize: CGSize(width: 400, height: 60),
                                  contentsScale: 2)
        XCTAssertGreaterThan(controller.currentGlyphs.count, 8)
        XCTAssertGreaterThan(controller.renderer.quadCount, 8)
        XCTAssertNotNil(controller.atlas)
        XCTAssertNotNil(controller.atlas?.entries["h"])

        // frame 变化重排：内容不变、quad 数不变（折行可能变）。
        try controller.relayout(viewportSize: CGSize(width: 100, height: 120),
                                contentsScale: 2)
        XCTAssertGreaterThan(controller.renderer.quadCount, 0)

        // 高频驱动不崩溃（无 drawable 时静默跳过）。
        controller.render(progress: 1.5)
    }
}
