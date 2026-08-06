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
// 录制中展示：左下工具栏 + 中部【取消】【结束录制】+ 右下录制指示器；
// 空闲状态仅展示：左下工具栏 + 右侧“未在录制”提示。

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

    /// 字幕区：译文在上（可选），原文居中；仅译文模式只显示译文。
    private var subtitleArea: some View {
        VStack(spacing: 3) {
            if !viewModel.translationOnly,
               let translation = viewModel.nonEmptyTranslation {
                Text(translation)
                    .font(.system(size: viewModel.translationFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            Text(viewModel.displayedSubtitleText)
                .font(.system(size: viewModel.sourceFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                // 空闲状态：不展示录制控件，仅保留右侧状态提示。
                Text("未在录制")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    /// 半透明圆角背景 + 细边框（长条浮层观感）。
    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: FloatingLetterMetrics.cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.34))
            .overlay(
                RoundedRectangle(cornerRadius: FloatingLetterMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(viewModel.borderOpacity), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
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
