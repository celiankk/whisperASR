import Foundation
import Metal
import AppKit

// MARK: - Metal 字词高亮字幕渲染器（CAMetalLayer + SDF 文本管线）
//
// 与 SubtitleHighlight.metal 配套（结构体字节布局必须逐字段一致，测试断言）。
//
// 性能模型（对比 CoreText/NSAttributedString 逐帧重排）：
// - **布局只在文本/词边界变化时执行一次**（updateGlyphLayout：CoreText 排版
//   → glyph quad 展开 → 预分配顶点缓冲），产出的几何不随进度变化；
// - 60~120fps 的词级进度刷新只写 48 字节 Uniform（三重缓冲轮转）+
//   提交一个已编码的 draw call——无布局、无新分配、无 ObjC 消息风暴；
// - SDF 抗锯齿在片段着色器完成，无 MSAA，缩放/移动零重光栅化。
//
// 线程模型：renderFrame(progress:) 设计为在主线程/专用渲染线程调用均可
// （CAMetalLayer 线程安全）；与外部时钟解耦——调用方拿到词级浮点进度后
// 直接驱动，本类不持有定时器。

// MARK: - 数据结构（字节布局与 MSL 一致）

/// 单 glyph quad 源数据（Swift 侧布局阶段产出）。
struct SubtitleGlyph {
    /// 字形外接框（layer 点坐标，左上原点，y 向下）。
    var rect: CGRect
    /// 该字形在 SDF 图集中的归一化 UV 矩形。
    var uvRect: CGRect
    /// 所属词索引（词级高亮单位）。
    var wordIndex: Int
}

/// 顶点（与 MSL `SubtitleVertex` 一致：stride 24B）。
struct SubtitleGPUVertex {
    var position: SIMD2<Float>   // 像素坐标，y 向下
    var uv: SIMD2<Float>
    var wordIndex: Float
}

/// 帧常量（与 MSL `SubtitleUniforms` 一致：48B，SIMD4 对齐 16）。
struct SubtitleUniforms {
    var viewportSize: SIMD2<Float>
    var progress: Float
    var sdfSmoothing: Float
    var inactiveColor: SIMD4<Float>   // straight RGBA
    var activeColor: SIMD4<Float>     // straight RGBA
}

/// 外观参数（进度插值两端的颜色 + SDF 平滑半宽）。
struct SubtitleAppearance {
    var inactiveColor: SIMD4<Float> = SIMD4(1.0, 1.0, 1.0, 0.55)  // 半透明白
    var activeColor: SIMD4<Float> = SIMD4(0.35, 0.78, 1.0, 1.0)   // 高亮青
    var sdfSmoothing: Float = 0.06
}

// MARK: - 渲染器

final class MetalSubtitleRenderer: NSObject {

    // MARK: 常量

    /// 顶点缓冲按此上界预分配（一次超长句 ~150 glyph，取 8 倍余量）。
    static let maxGlyphQuads = 4096
    /// Uniform 三重缓冲：与 CAMetalLayer maximumDrawableCount 对齐，
    /// 避免 CPU 覆写仍在 GPU 队列中的常量。
    private static let bufferSlotCount = 3

    // MARK: GPU 资源（全部 init 预分配，逐帧零分配）

    let device: MTLDevice
    let layer: CAMetalLayer
    let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    /// 字形图集（SDF，r8Unorm）——由宿主提供（msdf-atlas 等离线生成）。
    private var sdfAtlas: (any MTLTexture)?
    /// 顶点缓冲 × 3 槽（布局变化时三槽同步重写，渲染槽位无在途覆写风险）。
    private var vertexBuffers: [MTLBuffer]
    private let indexBuffer: MTLBuffer
    private var uniformBuffers: [MTLBuffer]
    private var uniformSlot = 0
    /// 当前生效的 glyph quad 数（0 = 无内容，跳过渲染）。
    private(set) var quadCount = 0
    /// drawable 像素尺寸（顶点已按此预缩放）。
    private(set) var viewportPixels: SIMD2<Float> = .zero
    var appearance = SubtitleAppearance()

    // MARK: 初始化

    /// - Parameter device: 注入 Metal 设备（默认系统主 GPU）。
    /// - Throws: 着色器资源缺失 / 编译失败 / 管线创建失败。
    init(device: MTLDevice) throws {
        self.device = device

        // 1. 着色器库：SPM 不编译 .metal → 运行时源码编译（一次，缓存）。
        //    SPM .copy 只保留资源目录名一级（bundle: Metal/SubtitleHighlight.metal），
        //    兼容不同 SPM 版本的两种落位。
        let shaderURL: URL
        if let url = Bundle.module.url(
            forResource: "SubtitleHighlight", withExtension: "metal", subdirectory: "Metal")
            ?? Bundle.module.url(forResource: "SubtitleHighlight", withExtension: "metal") {
            shaderURL = url
        } else {
            throw MetalRendererError.shaderResourceMissing
        }
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertexFn = library.makeFunction(name: "subtitleVertex"),
              let fragmentFn = library.makeFunction(name: "subtitleFragment") else {
            throw MetalRendererError.shaderFunctionMissing
        }

        // 2. 渲染管线：bgra8Unorm + 预乘 alpha 混合。
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        let colorAttachment = descriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = .bgra8Unorm
        colorAttachment.isBlendingEnabled = true
        // 片段输出预乘 alpha（rgb *= a）→ src 因子取 one。
        colorAttachment.sourceRGBBlendFactor = .one
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        // 3. 预分配缓冲区（显存/统一内存一次性落位，逐帧零分配）。
        let vertexStride = MemoryLayout<SubtitleGPUVertex>.stride
        vertexBuffers = (0..<Self.bufferSlotCount).map { _ in
            device.makeBuffer(length: Self.maxGlyphQuads * 4 * vertexStride,
                              options: .storageModeShared)!
        }
        // 索引缓冲：静态图案，init 一次生成终身复用。
        // 每 quad 两个三角形：(0,1,2) 与 (2,1,3)，顶点序 = 左上/左下/右上/右下。
        var indices = [UInt32]()
        indices.reserveCapacity(Self.maxGlyphQuads * 6)
        for quad in 0..<Self.maxGlyphQuads {
            let base = UInt32(quad * 4)
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base + 2, base + 1, base + 3])
        }
        indexBuffer = device.makeBuffer(bytes: indices,
                                        length: indices.count * MemoryLayout<UInt32>.stride,
                                        options: .storageModeShared)!
        uniformBuffers = (0..<Self.bufferSlotCount).map { _ in
            device.makeBuffer(length: MemoryLayout<SubtitleUniforms>.stride,
                              options: .storageModeShared)!
        }

        // 4. CAMetalLayer 配置。
        commandQueue = device.makeCommandQueue()!
        layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true          // 禁回读：WindowServer 直接扫描输出
        layer.isOpaque = false                // 悬浮字幕半透明合成
        layer.backgroundColor = NSColor.clear.cgColor
        layer.maximumDrawableCount = Self.bufferSlotCount
        layer.presentsWithTransaction = false // 异步呈现，不阻塞调用线程
        layer.allowsNextDrawableTimeout = false

        super.init()
    }

    deinit {
        // MTLBuffer/PipelineState 由 ARC 管理；CAMetalLayer 随宿主视图释放。
    }

    enum MetalRendererError: Error, Equatable {
        case shaderResourceMissing
        case shaderFunctionMissing
        case atlasMissing
        case glyphOverflow(count: Int)
    }

    // MARK: 布局（仅在文本/词边界变化时调用——非逐帧）

    /// 更新字形布局与视口。CoreText 排版结果 → quad 展开进预分配顶点缓冲。
    /// 进度刷新**不**经过本方法（只更新 Uniform）。
    /// - Parameters:
    ///   - glyphs: 排版产出的字形序列。
    ///   - viewportSize: layer 点尺寸（内容区）。
    ///   - contentsScale: backing scale（Retina 2x 等）。
    func updateGlyphLayout(_ glyphs: [SubtitleGlyph],
                           viewportSize: CGSize,
                           contentsScale: CGFloat) throws {
        guard glyphs.count <= Self.maxGlyphQuads else {
            throw MetalRendererError.glyphOverflow(count: glyphs.count)
        }
        let scale = Float(contentsScale)
        let pixels = CGSize(width: viewportSize.width * contentsScale,
                            height: viewportSize.height * contentsScale)
        // 零尺寸视口防御（宿视图首帧布局前 bounds=.zero）：跳过几何上传，
        // 置空渲染内容——drawableSize=(0,0) 会触发 Metal 断言。
        guard pixels.width > 0, pixels.height > 0 else {
            quadCount = 0
            return
        }
        viewportPixels = SIMD2(Float(pixels.width), Float(pixels.height))
        // 关键：drawableSize（像素）与 layer bounds（点）的比例必须一致，
        // 否则 WindowServer 合成时会把 drawable 二次缩放（Retina 上模糊）。
        layer.contentsScale = contentsScale
        layer.drawableSize = pixels

        quadCount = glyphs.count
        guard !glyphs.isEmpty else { return }

        let stride = MemoryLayout<SubtitleGPUVertex>.stride
        let vertexStrideBytes = Self.maxGlyphQuads * 4 * stride
        // 三槽同步重写（布局变化低频，3×memcpy 可忽略）。
        for slot in 0..<Self.bufferSlotCount {
            let base = vertexBuffers[slot].contents().bindMemory(
                to: SubtitleGPUVertex.self, capacity: Self.maxGlyphQuads * 4)
            for (q, glyph) in glyphs.enumerated() {
                let x0 = Float(glyph.rect.minX) * scale
                let y0 = Float(glyph.rect.minY) * scale
                let x1 = Float(glyph.rect.maxX) * scale
                let y1 = Float(glyph.rect.maxY) * scale
                let u0 = Float(glyph.uvRect.minX)
                let v0 = Float(glyph.uvRect.minY)
                let u1 = Float(glyph.uvRect.maxX)
                let v1 = Float(glyph.uvRect.maxY)
                let w = Float(glyph.wordIndex)
                let base4 = q * 4
                // 顶点序：左上 / 左下 / 右上 / 右下（与索引图案配对）。
                base[base4 + 0] = SubtitleGPUVertex(position: SIMD2(x0, y0), uv: SIMD2(u0, v0), wordIndex: w)
                base[base4 + 1] = SubtitleGPUVertex(position: SIMD2(x0, y1), uv: SIMD2(u0, v1), wordIndex: w)
                base[base4 + 2] = SubtitleGPUVertex(position: SIMD2(x1, y0), uv: SIMD2(u1, v0), wordIndex: w)
                base[base4 + 3] = SubtitleGPUVertex(position: SIMD2(x1, y1), uv: SIMD2(u1, v1), wordIndex: w)
            }
            // 清零本槽尾部（quadCount 之后的陈旧数据不可见，但保持确定性）。
            memset(base + glyphs.count * 4, 0, vertexStrideBytes - glyphs.count * 4 * stride)
        }
    }

    /// 绑定 SDF 图集（离线生成：msdf-atlas-gen / Stanton Moore 等 SDF 生成器产出）。
    func setSDFAtlas(_ texture: any MTLTexture) {
        sdfAtlas = texture
    }

    // MARK: 毫秒级渲染驱动（外部时钟解耦）

    /// 渲染一帧：只更新 Uniform + 提交已预分配资源的 draw call。
    /// 不取到 drawable（窗口遮挡/未挂载）时静默跳过——不阻塞调用方。
    /// - Parameter progress: 词级浮点进度（3.4 = 第 4 词过渡 40%）。
    @discardableResult
    func renderFrame(progress: Float) -> Bool {
        guard quadCount > 0, sdfAtlas != nil,
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }
        // Uniform 三重缓冲轮转（本帧唯一的数据写入：48 字节）。
        uniformSlot = (uniformSlot + 1) % Self.bufferSlotCount
        encodeDraw(into: commandBuffer,
                   colorTexture: drawable.texture,
                   progress: progress,
                   uniformSlot: uniformSlot)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    // MARK: 绘制指令编码（drawable 与编码解耦——离屏测试路径复用）

    /// 把当前 quad 几何 + 进度 Uniform 编码进给定命令缓冲。
    /// `renderFrame` 传入 drawable.texture；单测传入离屏渲染目标做像素断言。
    func encodeDraw(into commandBuffer: MTLCommandBuffer,
                    colorTexture: any MTLTexture,
                    progress: Float,
                    uniformSlot: Int = 0) {
        // 写 Uniform（storageModeShared：CPU 直写，无拷贝指挥）。
        let uniformsPtr = uniformBuffers[uniformSlot].contents()
            .bindMemory(to: SubtitleUniforms.self, capacity: 1)
        uniformsPtr.pointee = SubtitleUniforms(
            viewportSize: viewportPixels,
            progress: progress,
            sdfSmoothing: appearance.sdfSmoothing,
            inactiveColor: appearance.inactiveColor,
            activeColor: appearance.activeColor)

        let rpd = MTLRenderPassDescriptor()
        let attachment = rpd.colorAttachments[0]!
        attachment.texture = colorTexture
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffers[uniformSlot], offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
        encoder.setFragmentTexture(sdfAtlas, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: quadCount * 6,
                                      indexType: .uint32,
                                      indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)
        encoder.endEncoding()
    }
}
