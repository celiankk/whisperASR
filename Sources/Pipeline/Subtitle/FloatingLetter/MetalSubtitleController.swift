import Foundation
import AppKit
import Metal

// MARK: - Metal 字幕控制器（图集 / 排版 / 渲染三件套的组装与接线）
//
// 职责闭环（补齐 MetalSubtitleRenderer 的两个集成待办）：
// 1. **SDF 图集**：文本变化时按新字符集增量生成（SDFGlyphAtlasGenerator），
//    上传 r8Unorm 纹理注入渲染器；
// 2. **排版**：CoreText 引擎产出 [SubtitleGlyph]（含词索引 + 图集 UV），
//    frame 变化（拖拽缩放）时按存储的内容**重新排版**并重传 GPU——
//    同样的内容不同宽度，进度刷新仍只走 Uniform 路径。
//
// 调用契约（与 FloatingLetter 状态模型对接）：
// - 低频路径：setContent(text:words:)（字幕句变化）/ relayout（frame 变化）；
// - 高频路径：render(progress:)——progress 由外部时钟经
//   SubtitleGlyphLayoutEngine.progress(at:words:) 折算，毫秒级驱动。
//
// 线程：@MainActor（AppKit UI 域；CoreText 排版耗时 ms 级，可接受）。

@MainActor
final class MetalSubtitleController {

    let renderer: MetalSubtitleRenderer
    let layoutEngine: SubtitleGlyphLayoutEngine
    private(set) var atlas: SDFGlyphAtlas?

    /// 当前内容（frame 变化重排的依据）。
    private var currentText = ""
    private var currentWords: [WordTimestamp] = []
    private var currentViewport: CGSize = .zero
    private var currentScale: CGFloat = 2
    private(set) var currentGlyphs: [SubtitleGlyph] = []
    private(set) var wordCount = 0

    /// 宿主视图：layer = renderer.layer，frame 变化自动触发重排。
    /// lazy：初始化需要 self（控制器已完全构造后才能引用）。
    ///
    /// 状态：**当前零引用**（整条 Metal SDF 渲染链路尚未接线，只有
    /// MetalSubtitleRendererTests / MetalGlyphPipelineTests 引用本类型）。
    /// 接线到浮层时需要补一个 `NSViewRepresentable` 桥把本视图塞进
    /// SwiftUI 视图树；`frameDidChange` 会在 postsFrameChangedNotifications
    /// 下**每帧**触发 `relayout` → `rebuild`（全量重建 SDF 图集 + CoreText
    /// 重排），接线前应先做「仅重排不上图集」的快路径与图集缓存。
    lazy var hostView: NSView = MetalSubtitleHostView(controller: self)

    /// - Parameter rasterFontSize: SDF 栅格化字号（边缘精度；与排版字号解耦）。
    init(font: NSFont = .systemFont(ofSize: 17, weight: .semibold),
         rasterFontSize: CGFloat = 96,
         device: MTLDevice? = nil) throws {
        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalSubtitleRenderer.MetalRendererError.shaderResourceMissing
        }
        renderer = try MetalSubtitleRenderer(device: metalDevice)
        layoutEngine = SubtitleGlyphLayoutEngine(font: font)
        atlas = SDFGlyphAtlasGenerator.generate(text: "", font: font as CTFont,
                                                rasterFontSize: rasterFontSize)
        if let atlasTexture = atlas?.makeTexture(device: metalDevice) {
            renderer.setSDFAtlas(atlasTexture)
        }
    }

    /// 设置字幕内容（句变化时调用；图集按需重建 + 排版 + 上传）。
    func setContent(text: String, words: [WordTimestamp],
                    viewportSize: CGSize, contentsScale: CGFloat) throws {
        currentText = text
        currentWords = words
        currentViewport = viewportSize
        currentScale = contentsScale
        wordCount = words.count
        try rebuild(text: text, words: words,
                    viewportSize: viewportSize, contentsScale: contentsScale)
    }

    /// frame 变化（拖拽缩放）：同内容重排版（宽度变了折行变化）。
    func relayout(viewportSize: CGSize, contentsScale: CGFloat) throws {
        guard viewportSize != currentViewport || contentsScale != currentScale else { return }
        currentViewport = viewportSize
        currentScale = contentsScale
        try rebuild(text: currentText, words: currentWords,
                    viewportSize: viewportSize, contentsScale: contentsScale)
    }

    /// 高频驱动：外部时钟已折算的词级进度。
    func render(progress: Float) {
        renderer.renderFrame(progress: progress)
    }

    /// 外部时钟 → 词级进度（方便调用方直连）。
    static func progress(at time: Double, words: [WordTimestamp]) -> Float {
        SubtitleGlyphLayoutEngine.progress(at: time, words: words)
    }

    // MARK: 内部

    private func rebuild(text: String, words: [WordTimestamp],
                         viewportSize: CGSize, contentsScale: CGFloat) throws {
        // 1. 图集增量重建（新字符集；句级低频，重打包成本可忽略——
        //    字符级缓存为后续优化项）。
        let ctFont = layoutEngine.font as CTFont
        let newAtlas = SDFGlyphAtlasGenerator.generate(
            text: text, font: ctFont,
            rasterFontSize: atlas?.rasterFontSize ?? 96)
        atlas = newAtlas
        if let texture = newAtlas.makeTexture(device: renderer.device) {
            renderer.setSDFAtlas(texture)
        }

        // 2. 排版（CoreText，一次）→ glyph quad 上传 GPU。
        let result = layoutEngine.layout(text: text, width: viewportSize.width,
                                         atlas: newAtlas, wordTimestamps: words)
        currentGlyphs = result.glyphs
        try renderer.updateGlyphLayout(result.glyphs,
                                       viewportSize: viewportSize,
                                       contentsScale: contentsScale)
    }
}

// MARK: 宿主视图

/// 承载 CAMetalLayer 的透明 NSView：frame 变化（拖拽/缩放）→ 控制器重排。
final class MetalSubtitleHostView: NSView {
    private weak var controller: MetalSubtitleController?

    init(controller: MetalSubtitleController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer = controller.renderer.layer
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification, object: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }   // 与排版 y 向下坐标系一致

    @objc private func frameDidChange() {
        guard let controller else { return }
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        try? controller.relayout(viewportSize: bounds.size, contentsScale: scale)
    }
}
