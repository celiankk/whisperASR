import AppKit
import SwiftUI
import Observation

// MARK: - 样式常量

enum FloatingLetterMetrics {
    /// 浮层圆角（长条半透明圆角浮层）。
    static let cornerRadius: CGFloat = 16
    /// 展开态尺寸（长条）。
    static let expandedSize = CGSize(width: 1080, height: 150)
    /// 紧凑态尺寸（缩放箭头收起后的小药丸）。
    static let compactSize = CGSize(width: 300, height: 46)
    /// 淡入淡出动画时长。
    static let fadeDuration: TimeInterval = 0.25
}

// MARK: - 浮层根容器
//
// 布局（对照效果图，自顶向下）：
// ┌────────────────────────────────────────────────────────────┐
// │                                                      ( X ) │  最右侧：圆形叉号
// │                    字幕文本（居中展示）                        │  浮层中间
// │  [工具栏图标组]   [取消][结束录制]    ● 应用名 00:12        │  左下/中部/右下
// └────────────────────────────────────────────────────────────┘
// 选择应用已解耦为独立弹窗（FloatingAppPicker），本容器只负责字幕浮层：
// 录制中展示：左下工具栏 + 中部【取消】【结束录制】+ 右下录制指示器；
// 空闲状态：左下工具栏 + 【开始录制】按钮（唤起独立弹窗）+ 右侧“未在录制”提示。

struct FloatingLetterContainerView: View {
    let viewModel: FloatingLetterViewModel

    var body: some View {
        Group {
            if viewModel.isCompact {
                compactContent
            } else {
                expandedContent
            }
        }
        .background(panelBackground)
        .onAppear {
            // 出现即开始 5 秒倒计时。
            viewModel.viewDidAppear()
        }
        .onDisappear {
            // 视图销毁时主动 invalidate 定时器，防止内存泄漏。
            viewModel.viewDidDisappear()
        }
    }

    // MARK: 展开态

    private var expandedContent: some View {
        VStack(spacing: 4) {
            // 最右侧：关闭浮层圆形叉号按钮
            HStack {
                Spacer(minLength: 0)
                closeButton
            }
            .frame(height: 20)

            // 浮层中间：字幕文本
            subtitleArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部：工具栏 / 录制控制
            bottomBar
                .frame(height: 30)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
    }

    // MARK: 紧凑态（缩放箭头收起）

    private var compactContent: some View {
        Button(action: {
            viewModel.toggleCompact()
        }) {
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(viewModel.displayedSubtitleText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("展开浮层")
    }

    // MARK: 子区域

    /// 关闭按钮（最右侧圆形叉号）。
    private var closeButton: some View {
        Button(action: {
            viewModel.close()
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("关闭字幕浮层")
    }

    /// 字幕区：SubtitleContainerLayer（背景/圆角/位置）→ SubtitleTextLayer（文字）。
    /// 容器尺寸来自 SubtitleContainerConfig，与字号完全解耦（字号不改变窗口大小）。
    private var subtitleArea: some View {
        Group {
            if !viewModel.translationOnly, viewModel.subtitleTextVisible {
                subtitleContainerLayer
            } else {
                // 仅译文模式 / 字幕隐藏：保持原单行渲染逻辑。
                sourceSubtitleView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            debugOverlay
        }
        #endif
    }

    /// SubtitleContainerLayer：文字层 + 可配置编辑边框。
    /// 背景已合一：整窗只有 panelBackground 一层半透明背景（透明度由
    /// 「字幕背景不透明度」控制）——内层不再叠加自己的背景/描边，否则
    /// 字幕区被双重压暗、与外围透明度不符。
    /// 容器尺寸来自 SubtitleContainerConfig，与字号完全解耦。
    private var subtitleContainerLayer: some View {
        ZStack {
            subtitleTextLayer

            // 字幕编辑边框（可设置隐藏/颜色/透明度；只影响视觉，不影响移动缩放）。
            if viewModel.subtitleEditBorderVisible {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        borderColor.opacity(viewModel.subtitleEditBorderOpacity),
                        lineWidth: 1.5
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 内容裁剪：字幕文字只能显示在容器内部，禁止溢出。
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // 容器不接收 SwiftUI 事件：移动/缩放全部交给 NSWindow 原生处理。
        .allowsHitTesting(false)
        .help("拖动任意空白处移动窗口；拖动边缘/四角缩放")
        .compositingGroup()
    }

    /// 编辑边框颜色（hex → Color；解析失败回退白色）。
    private var borderColor: Color {
        let hex = viewModel.subtitleEditBorderColorHex.trimmingCharacters(in: .whitespaces)
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return .white }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }

    /// SubtitleTextLayer：原文（上）+ 译文（下）同时显示；
    /// 字号/粗细/行间距/对齐只影响本层，不影响容器/窗口尺寸。
    private var subtitleTextLayer: some View {
        let horizontal: HorizontalAlignment =
            viewModel.subtitleTextAlignment == .leading ? .leading : .center
        let lineAlignment = Alignment(
            horizontal: viewModel.subtitleTextAlignment == .leading ? .leading : .center,
            vertical: .center)
        return VStack(alignment: horizontal, spacing: viewModel.subtitleLineSpacing) {
            Spacer(minLength: 0)
            // 原文区（始终显示）。末行是正在增长的活跃行：用逐字入场动画
            // （公共前缀 diff——已显示的字保持静态，只有新增字淡入上移），
            /// 流式追加呈现平滑打字感；非末行已定型，普通 Text 静态渲染。
            let sourceLines = viewModel.renderer.lines
            ForEach(Array(sourceLines.enumerated()), id: \.offset) { index, line in
                if index == sourceLines.count - 1 {
                    SplitSubtitleText(
                        text: line,
                        fontSize: viewModel.sourceFontSize,
                        fontWeight: subtitleFontWeight,
                        foregroundStyle: .white,
                        staggerDelay: 0.045,
                        duration: 0.32,
                        fromOffsetY: 12,
                        fromScale: 0.95,
                        alignment: lineAlignment
                    )
                    .lineLimit(nil) // 逻辑层控制内容，禁止 "..." 截断
                } else {
                    Text(line)
                        .font(.system(size: viewModel.sourceFontSize, weight: subtitleFontWeight))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(viewModel.subtitleTextAlignment)
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: lineAlignment)
                }
            }
            // 译文区（有译文时显示在原文下方，译文字号独立设置；
            // 变化带淡入过渡）。
            if viewModel.showingTranslation, !viewModel.translationRenderer.lines.isEmpty {
                ForEach(Array(viewModel.translationRenderer.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: viewModel.translationFontSize, weight: subtitleFontWeight))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(viewModel.subtitleTextAlignment)
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: lineAlignment)
                        .animation(.easeOut(duration: 0.2), value: line)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: viewModel.renderer.text)
        .animation(.easeOut(duration: 0.18), value: viewModel.translationRenderer.text)
    }

    /// 字体粗细映射（regular / medium→semibold 保持当前风格 / bold）。
    private var subtitleFontWeight: Font.Weight {
        switch viewModel.subtitleFontWeight {
        case "regular": return .regular
        case "bold": return .bold
        default: return .semibold
        }
    }

    /// 调试信息（开发模式）：状态机 / ASR / 语言 / 翻译 / 字幕 / 耗时 / 引擎。
    @ViewBuilder
    private var debugOverlay: some View {
        if let debug = viewModel.debugInfo {
            VStack(alignment: .leading, spacing: 1) {
                Text("State: \(viewModel.subtitleState.rawValue)")
                Text("ASR: \(debug.asrText)")
                Text("Language: \(debug.detectedLanguage)")
                Text("Audio Level: \(debug.audioLevelText)")
                Text("Translation: \(debug.translationStatus)")
                Text("Subtitle: \(debug.subtitle)")
                Text("耗时: \(debug.latencyMs) ms")
                Text(debug.engineInfo)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(1)
        }
    }

    /// 主字幕行：实时识别文本使用逐字入场动画；
    /// 仅译文模式、空状态/占位文本保持普通 Text（避免占位文案也播放动画）。
    @ViewBuilder
    private var sourceSubtitleView: some View {
        if !viewModel.translationOnly,
           viewModel.subtitleTextVisible,
           !viewModel.subtitleText.isEmpty {
            SplitSubtitleText(
                text: viewModel.subtitleText,
                fontSize: viewModel.sourceFontSize,
                fontWeight: .semibold,
                foregroundStyle: .white,
                staggerDelay: 0.06,
                duration: 0.5,
                fromOffsetY: 28,
                fromScale: 0.92
            )
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text(viewModel.displayedSubtitleText)
                .font(.system(size: viewModel.sourceFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(nil)
                .multilineTextAlignment(viewModel.subtitleTextAlignment)
        }
    }

    /// 控制层（ControlLayer）：半透明悬浮控制条（macOS 浮动控制栏观感），
    /// 位于字幕区下方，不遮挡字幕；5 秒无操作自动隐藏（字幕层不受影响）；
    /// 收起按钮在「结束录制」一侧（右下角），手动折叠功能区（胶囊收缩为
    /// 只包住按钮本身，钉在右下角，不残留原宽度的空白条带），再点展开。
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if !viewModel.controlsCollapsed {
                FloatingLetterToolbarView(viewModel: viewModel)

                Spacer(minLength: 8)

                if viewModel.isRecording {
                    // 录制状态：展示录制相关控件（中部按钮 + 右下指示器）。
                    FloatingLetterRecordBarView(viewModel: viewModel)
                } else {
                    // 空闲状态：提供“开始录制”入口 + 右侧状态提示。
                    Button {
                        viewModel.startAppSelection()
                    } label: {
                        Label("开始录制", systemImage: "record.circle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .help("选择要录制的应用")
                    Text("未在录制")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            controlsCollapseButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(.ultraThinMaterial).opacity(0.45)
        )
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        // 胶囊按内容自适应宽度：展开时内容撑满整行；收起时只包住按钮。
        // 外层 frame 占满宽度并钉在右侧（结束录制一侧）——收起后胶囊
        // 收缩、位置不变，布局槽位稳定（字幕区不跳动），不残留条带。
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(viewModel.controlsVisible ? 1 : 0)
        .allowsHitTesting(viewModel.controlsVisible)
        .animation(.easeOut(duration: 0.2), value: viewModel.controlsVisible)
        .animation(.easeOut(duration: 0.2), value: viewModel.controlsCollapsed)
    }

    /// 功能区收起/展开按钮（收起后仅保留本按钮，5 秒无操作仍会自动隐藏，
    /// 鼠标移入浮层再显示时保持收起状态）。
    private var controlsCollapseButton: some View {
        Button {
            viewModel.toggleControlsCollapsed()
        } label: {
            Image(systemName: viewModel.controlsCollapsed ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(viewModel.controlsCollapsed ? "展开功能区" : "收起功能区")
    }

    /// 半透明圆角背景 + 细边框（长条浮层观感）。
    /// 整窗唯一一层背景：透明度由「字幕背景不透明度」设置控制
    /// （设置页字幕样式滑杆），字幕区与外围完全一体。
    private var panelBackground: some View {
        // 黑色半透明浮窗背景：保证白色字幕/图标在浅色桌面上可读。
        // 只负责背景/圆角，不参与任何动画；窗口阴影由 AppKit 系统绘制。
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.black.opacity(viewModel.subtitleBackgroundOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(min(viewModel.borderOpacity, 0.05)), lineWidth: 0.5)
            )
            .compositingGroup()
    }
}

// MARK: - 左下角图标工具栏

struct FloatingLetterToolbarView: View {
    let viewModel: FloatingLetterViewModel

    var body: some View {
        HStack(spacing: 10) {
            // 对话气泡：暂停/继续翻译
            toolButton(
                icon: viewModel.isTranslationPaused ? "character.bubble" : "character.bubble.fill",
                active: !viewModel.isTranslationPaused,
                activeColor: .blue,
                help: viewModel.isTranslationPaused ? "继续翻译" : "暂停翻译（例如：说话人切换到你的语言）"
            ) {
                viewModel.toggleTranslationPause()
            }

            // 眼睛：原文+译文 / 仅译文
            toolButton(
                icon: viewModel.translationOnly ? "eye.fill" : "eye",
                active: viewModel.translationOnly,
                activeColor: .blue,
                help: viewModel.translationOnly ? "显示原文和翻译" : "仅显示翻译"
            ) {
                viewModel.toggleTranslationOnly()
            }

            // 字幕：显示/隐藏字幕文本
            toolButton(
                icon: viewModel.subtitleTextVisible ? "captions.bubble.fill" : "captions.bubble",
                active: viewModel.subtitleTextVisible,
                activeColor: .blue,
                help: viewModel.subtitleTextVisible ? "隐藏字幕文本" : "显示字幕文本"
            ) {
                viewModel.toggleSubtitle()
            }

            // 置顶图钉：窗口保持置顶
            toolButton(
                icon: viewModel.isPinned ? "pin.fill" : "pin",
                active: viewModel.isPinned,
                activeColor: .orange,
                help: viewModel.isPinned ? "取消窗口置顶" : "保持在所有窗口顶部"
            ) {
                viewModel.togglePin()
            }

            // 鼠标穿透：开启后点击直接穿过字幕窗口（只显示字幕）。
            toolButton(
                icon: "arrow.up.right",
                active: viewModel.mousePassthrough,
                activeColor: .blue,
                help: viewModel.mousePassthrough
                    ? "关闭鼠标穿透（恢复窗口交互）"
                    : "开启鼠标穿透（点击穿过字幕窗口）",
            ) {
                viewModel.toggleMousePassthrough()
            }

            // 缩放箭头：展开/收起浮层
            toolButton(
                icon: viewModel.isCompact
                    ? "arrow.up.left.and.arrow.down.right"
                    : "arrow.down.right.and.arrow.up.left",
                active: false,
                activeColor: .blue,
                help: viewModel.isCompact ? "展开浮层" : "收起浮层"
            ) {
                viewModel.toggleCompact()
            }
        }
    }

    private func toolButton(
        icon: String,
        active: Bool,
        activeColor: Color,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? activeColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(active ? activeColor.opacity(0.14) : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

// MARK: - 录制控制栏（录制状态专属）
//
// 中部：【取消】【结束录制】按钮；右下角：红点录制指示器、监听软件名称、录制时长。

struct FloatingLetterRecordBarView: View {
    let viewModel: FloatingLetterViewModel
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Button("取消") {
                viewModel.cancelRecording()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .help("取消录制")

            Button("结束录制") {
                viewModel.endRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .font(.system(size: 12, weight: .semibold))
            .help("结束录制并保存")

            // 分隔线：按钮区与指示器区分开
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 14)

            // 录制指示器（红点，呼吸动画）
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.35 : 1)
                .animation(
                    .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                    value: pulsing
                )
                .onAppear { pulsing = true }

            // 监听软件名称
            Text(viewModel.recordingAppName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)

            // 录制时长（等宽字体，避免数字跳动时抖动）
            Text(viewModel.recordingDurationText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
