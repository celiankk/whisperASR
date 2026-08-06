import AppKit
import SwiftUI
import Observation

// MARK: - 样式常量

enum FloatingLetterMetrics {
    /// 浮层圆角（长条半透明圆角浮层）。
    static let cornerRadius: CGFloat = 16
    /// 展开态尺寸（长条）。
    static let expandedSize = CGSize(width: 760, height: 118)
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

    /// 字幕区：底部对齐的固定高度区域。
    /// 行数由 maxLines 决定，浮框高度随内容自适应（见控制器 targetSize）。
    private var subtitleArea: some View {
        Group {
            if !viewModel.translationOnly, viewModel.subtitleTextVisible {
                subtitleStackView
            } else {
                // 仅译文模式 / 字幕隐藏：保持原单行渲染逻辑。
                sourceSubtitleView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// 字幕层级：
    ///   SubtitleContainer（本容器）→ SubtitleLine（行级状态）→ SplitSubtitleText（字符级）
    /// - 历史行：opacity 0.3 / y -20，超出 maxLines 时从最旧开始逐行退出并移除；
    /// - 当前行（最多 2 条）：opacity 1 / y 0，SplitText 字符动画；interim 普通文本直出；
    /// - 动画分层：SubtitleContainer（本容器）负责行级位移/透明度，
    ///   SplitSubtitleText 只负责字符级入场，互不冲突；
    /// - 底部对齐；容器高度由内容撑开，不裁剪历史字幕。
    private var subtitleStackView: some View {
        VStack(spacing: 3) {
            Spacer(minLength: 0)

            // 历史字幕（灰 30%）：位于主字幕上方，只占剩余空间。
            ForEach(viewModel.historyLines) { history in
                SubtitleLineView(
                    text: history.text,
                    translation: history.translation,
                    isCurrent: false,
                    isExiting: history.status == .exiting,
                    isPlaying: viewModel.isPlaying,
                    sourceFontSize: viewModel.sourceFontSize,
                    translationFontSize: viewModel.translationFontSize
                )
                .id(history.id)
                .transition(.opacity)
            }

            // 当前主字幕行（白 100%，最多 2 条，SplitText 字符动画）。
            ForEach(viewModel.currentLines) { current in
                SubtitleLineView(
                    text: current.text,
                    translation: current.translation,
                    isCurrent: true,
                    isExiting: false,
                    isPlaying: viewModel.isPlaying,
                    sourceFontSize: viewModel.sourceFontSize,
                    translationFontSize: viewModel.translationFontSize
                )
                .id(current.id)
                .transition(.opacity)
            }

            // 流式临时句（普通文本，不触发动画）。
            if !viewModel.interimText.isEmpty {
                interimLineView
                .id("interim")
                .transition(.opacity)
            } else if viewModel.currentLines.isEmpty, viewModel.historyLines.isEmpty {
                Text("字幕浮层已就绪")
                    .font(.system(size: viewModel.sourceFontSize * 0.7, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // 独立渲染层：只承载字幕内容动画（行移动/透明度/逐字入场），
        // 与浮窗背景层分离，避免同一元素同时控制 transform/opacity/背景。
        .compositingGroup()
        // 暂停时完全禁用行级动画，保持布局静止。
        .animation(viewModel.isPlaying ? .easeOut(duration: 0.35) : nil, value: viewModel.historyLines)
        .animation(viewModel.isPlaying ? .easeOut(duration: 0.35) : nil, value: viewModel.currentLines)
        .animation(viewModel.isPlaying ? .easeOut(duration: 0.35) : nil, value: viewModel.interimText.isEmpty)
    }

    /// 流式临时句：普通文本直出，不进入历史、不触发 SplitText。
    private var interimLineView: some View {
        VStack(spacing: 1) {
            if let translation = viewModel.interimTranslation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: viewModel.translationFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            Text(viewModel.interimText)
                .font(.system(size: viewModel.sourceFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
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
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
        }
    }

    /// 底部栏：左下工具栏 + 中部录制按钮 + 右下录制指示器。
    private var bottomBar: some View {
        HStack(spacing: 12) {
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
    }

    /// 半透明圆角背景 + 细边框（长条浮层观感）。
    private var panelBackground: some View {
        // macOS 原生毛玻璃浮窗层：只负责背景/圆角/材质，不参与任何动画。
        // - 系统毛玻璃（ultraThinMaterial）+ 半透明白 12%（类似 backdrop blur 20px）；
        // - 连续圆角 20pt，无粗白描边；
        // - 窗口阴影由 AppKit 系统绘制（hasShadow），不再叠加 SwiftUI 阴影，
        //   避免圆角边缘出现白色锯齿/灰边。
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(min(viewModel.borderOpacity, 0.05)), lineWidth: 0.5)
            )
            .compositingGroup()
    }
}

// MARK: - 字幕行（行级容器动画）
//
// 分层职责：
// - 行容器（本视图）：整体 opacity / translateY —— 当前行 1.0 / 0，
//   历史行 0.3 / -20；行状态变化时只动画这两个属性；
// - SplitSubtitleText（内部）：只做字符级入场（chars opacity/y/scale）。
// 两层控制不同视图的相同属性，互不冲突；历史行不重播字符动画。

private struct SubtitleLineView: View {
    let text: String
    let translation: String?
    /// 当前行（最新字幕）：完全显示；历史行：压暗并上移。
    let isCurrent: Bool
    /// 历史行是否已进入退出动画（0.3 → 0 / -20 → -50，只执行一次）。
    let isExiting: Bool
    /// 播放状态：暂停时冻结本行动画（透明度/位移不重算）。
    let isPlaying: Bool
    let sourceFontSize: CGFloat
    let translationFontSize: CGFloat

    var body: some View {
        VStack(spacing: 1) {
            if let translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: translationFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            if isCurrent {
                // 当前行：SplitText 只做字符级入场。
                SplitSubtitleText(
                    text: text,
                    fontSize: sourceFontSize,
                    fontWeight: .semibold,
                    foregroundStyle: .white,
                    staggerDelay: 0.05,
                    duration: 0.5,
                    fromOffsetY: 26,
                    fromScale: 0.93
                )
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // 历史行：字符已播放过，用普通文本，禁止重播。
                Text(text)
                    .font(.system(size: sourceFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .opacity(isExiting ? 0 : (isCurrent ? 1 : 0.3))
        .offset(y: isExiting ? -50 : (isCurrent ? 0 : -20))
        .animation(isPlaying ? .easeOut(duration: 0.4) : nil, value: isExiting)
        .animation(isPlaying ? .easeOut(duration: 0.4) : nil, value: isCurrent)
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
