import XCTest
import Metal
@testable import WhisperASR

// MARK: - Metal 字幕渲染管线测试（离屏渲染 + 像素回读）
//
// 不依赖 CAMetalLayer（headless 友好）：encodeDraw(into:colorTexture:)
// 渲染到离屏纹理，waitUntilCompleted 后回读字节做端到端像素断言——
// 覆盖 SDF 抗锯齿、词级进度插值、混合与布局展开的完整 GPU 路径。
final class MetalSubtitleRendererTests: XCTestCase {

    private func makeRenderer() throws -> (MetalSubtitleRenderer, MTLDevice) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        let renderer = try MetalSubtitleRenderer(device: device)
        return (renderer, device)
    }

    /// 满视口单 glyph + 人造 SDF 图集（左半 0=外部，右半 1=内部）。
    private func setupFullQuad(_ renderer: MetalSubtitleRenderer,
                               _ device: MTLDevice,
                               viewport: CGSize) throws {
        let atlas = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: 8, height: 8, mipmapped: false)
            d.usage = [.shaderRead]
            return d
        }())!
        // 左半（列 0-3）= 0（字形外），右半（列 4-7）= 1（字形内）。
        var texels = [UInt8](repeating: 0, count: 64)
        for row in 0..<8 {
            for col in 0..<8 {
                texels[row * 8 + col] = col >= 4 ? 255 : 0
            }
        }
        atlas.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0,
                      withBytes: texels, bytesPerRow: 8)
        renderer.setSDFAtlas(atlas)

        try renderer.updateGlyphLayout(
            [SubtitleGlyph(rect: CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height),
                           uvRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                           wordIndex: 0)],
            viewportSize: viewport,
            contentsScale: 1)
    }

    /// 渲染到离屏纹理并回读 BGRA 字节。
    private func renderOffscreen(_ renderer: MetalSubtitleRenderer,
                                 _ device: MTLDevice,
                                 progress: Float,
                                 size: CGSize) throws -> [UInt8] {
        let texture = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            return d
        }())!
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            XCTFail("command buffer creation failed")
            return []
        }
        renderer.encodeDraw(into: commandBuffer, colorTexture: texture, progress: progress)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        texture.getBytes(&bytes, bytesPerRow: Int(size.width) * 4,
                         from: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)),
                         mipmapLevel: 0)
        return bytes
    }

    private func byteAt(_ bytes: [UInt8], _ x: Int, _ y: Int, channel: Int, width: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + channel]
    }

    // MARK: 结构体字节布局（与 MSL 契约）

    func testGPUStructLayoutMatchesMSL() {
        // MSL: float2(align8) + float2(align8) + float → stride 24。
        XCTAssertEqual(MemoryLayout<SubtitleGPUVertex>.stride, 24)
        // MSL: float2(8) + float(4) + float(4) + float4(align16 @16) + float4 @32 → stride 48。
        XCTAssertEqual(MemoryLayout<SubtitleUniforms>.stride, 48)
        XCTAssertEqual(MemoryLayout<SubtitleUniforms>.alignment, 16)
    }

    // MARK: 管线创建

    func testPipelineStateCreation() throws {
        let (renderer, _) = try makeRenderer()
        XCTAssertFalse(renderer.layer.isOpaque)
        XCTAssertEqual(renderer.layer.pixelFormat, .bgra8Unorm)
        XCTAssertTrue(renderer.layer.framebufferOnly)
        // 初始无内容：renderFrame 静默跳过。
        XCTAssertFalse(renderer.renderFrame(progress: 0))
    }

    // MARK: 布局展开

    func testGlyphLayoutExpandsQuads() throws {
        let (renderer, _) = try makeRenderer()
        let glyphs = (0..<10).map { i in
            SubtitleGlyph(rect: CGRect(x: CGFloat(i) * 20, y: 0, width: 18, height: 24),
                          uvRect: CGRect(x: 0, y: 0, width: 0.1, height: 1),
                          wordIndex: i / 3)
        }
        try renderer.updateGlyphLayout(glyphs, viewportSize: CGSize(width: 400, height: 60),
                                       contentsScale: 2)
        XCTAssertEqual(renderer.quadCount, 10)
        XCTAssertEqual(renderer.viewportPixels, SIMD2(800, 120))
        XCTAssertEqual(renderer.layer.drawableSize, CGSize(width: 800, height: 120))

        // 超界拒绝（预分配上界契约）。
        XCTAssertThrowsError(try renderer.updateGlyphLayout(
            Array(repeating: glyphs[0], count: MetalSubtitleRenderer.maxGlyphQuads + 1),
            viewportSize: CGSize(width: 400, height: 60), contentsScale: 2))
    }

    // MARK: 端到端像素：SDF 抗锯齿 + 词级进度插值

    func testPixelOutputProgressHighlight() throws {
        let (renderer, device) = try makeRenderer()
        let viewport = CGSize(width: 64, height: 64)
        try setupFullQuad(renderer, device, viewport: viewport)

        // progress=5，唯一 glyph 是词 0 → 高亮 t=1：右半（SDF=1）不透明高亮色，
        // 左半（SDF=0）alpha=0 透明（clear 色）。
        var bytes = try renderOffscreen(renderer, device, progress: 5.0, size: viewport)
        // 右半中心 (48, 32)：alpha 255，RGB = 高亮青预乘 (89, 199, 255)。
        let (r, g, b, a) = (Int(byteAt(bytes, 48, 32, channel: 2, width: 64)),
                            Int(byteAt(bytes, 48, 32, channel: 1, width: 64)),
                            Int(byteAt(bytes, 48, 32, channel: 0, width: 64)),
                            Int(byteAt(bytes, 48, 32, channel: 3, width: 64)))
        XCTAssertEqual(a, 255)
        XCTAssertEqual(r, 89, accuracy: 2)
        XCTAssertEqual(g, 199, accuracy: 2)
        XCTAssertEqual(b, 255, accuracy: 2)
        // 左半中心 (16, 32)：alpha 0（背景 clear 透出）。
        XCTAssertEqual(Int(byteAt(bytes, 16, 32, channel: 3, width: 64)), 0)

        // progress=-1 → t=0：未激活色（白 0.55 → 预乘 alpha 140）。
        bytes = try renderOffscreen(renderer, device, progress: -1.0, size: viewport)
        let inactiveA = Int(byteAt(bytes, 48, 32, channel: 3, width: 64))
        XCTAssertEqual(inactiveA, 140, accuracy: 2)
        let inactiveR = Int(byteAt(bytes, 48, 32, channel: 2, width: 64))
        XCTAssertEqual(inactiveR, 140, accuracy: 2, "premultiplied inactive white rgb==alpha")
    }

    /// 词级过渡的线性插值：progress=0.5 时同一词内亮度处于两色中间。
    func testPixelOutputMidTransitionInterpolates() throws {
        let (renderer, device) = try makeRenderer()
        try setupFullQuad(renderer, device, viewport: CGSize(width: 64, height: 64))

        // 半透明混合在黑底上合成：alpha 通道可直接读（attachment 自身值）。
        let bytes = try renderOffscreen(renderer, device, progress: 0.5, size: CGSize(width: 64, height: 64))
        // t=0.5：alpha = mix(0.55, 1.0, 0.5) = 0.775 → 198。
        let a = Int(byteAt(bytes, 48, 32, channel: 3, width: 64))
        XCTAssertEqual(a, 198, accuracy: 3)
    }
}
