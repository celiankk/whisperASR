import AVFoundation
import CoreGraphics
import SwiftUI

// MARK: - 首次引导（三步）

/// 首次引导：① 管线自演示 → ② 权限与模型 → ③ 开录路径（菜单栏入口）。
///
/// 动效规格（移植 recent.design 的两个关键帧与缓动）：
/// • 入场：fade-in + offset(y:8)，主曲线 cubic-bezier(.16,1,.3,1)，stagger 45ms
///   —— 与字幕逐字入场的 0.045 同口径，全 App 只有一种节奏感；
/// • 打字机 + 光标 blink 1.06s（站点 input-caret-blink）；
/// • 波形条用 Canvas + TimelineView 自绘，不产生视图重建；
/// • 系统「减少动态效果」开启时：全部退化为直接落终态（Motion 闸门）。
struct OnboardingView: View {
    var onComplete: (() -> Void)?

    @State private var step = 0
    @State private var revealed = false

    private let stepTitles = ["它怎么工作", "准备工作", "开始使用"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer().frame(height: Metrics.xxxl)

            ZStack {
                switch step {
                case 0: PipelineStep(revealed: revealed)
                case 1: PermissionsStep()
                default: ShortcutStep(revealed: revealed)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 56)
            .animation(Motion.anim(Motion.exit(0.34)), value: step)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // 入场编排：先让容器可见，再逐项淡入。
            try? await Task.sleep(for: .milliseconds(60))
            Motion.run(Motion.exit(0.5)) { revealed = true }
        }
    }

    // MARK: 顶部：品牌胶囊 + 步骤指示

    private var header: some View {
        VStack(spacing: Metrics.xl) {
            HStack(spacing: 6) {
                Circle().fill(Palette.ok).frame(width: 6, height: 6)
                Text("声记 SonicScribe")
                    .foregroundStyle(Ink.secondary)
                Text("ready")
                    .foregroundStyle(Ink.secondary.opacity(0.7))
            }
            .font(Type.mono(Type.caption, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Corner.rect(Corner.small).fill(Ink.subtle))
            .overlay(Corner.rect(Corner.small).strokeBorder(Ink.hairline, lineWidth: 0.5))
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 8)

            // 步骤指示：等宽标题 + 4pt 圆点（当前点用 accent，位移带缓动）。
            HStack(spacing: Metrics.md) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(index == step ? Color.accentColor : Ink.active)
                            .frame(width: 4, height: 4)
                            .animation(Motion.anim(Motion.standard(0.26)), value: step)
                        Text(stepTitles[index])
                            .font(Type.mono(Type.micro, weight: index == step ? .medium : .regular))
                            .foregroundStyle(index == step ? Color.primary : Ink.secondary)
                    }
                    .onTapGesture { if index <= step { Motion.run(Motion.standard(0.24)) { step = index } } }
                }
            }
            .opacity(revealed ? 1 : 0)
        }
        .padding(.top, 36)
    }

    // MARK: 底部：上一步 / 下一步 / 完成

    private var footer: some View {
        HStack(spacing: Metrics.lg) {
            if step > 0 {
                Button("上一步") { Motion.run(Motion.standard(0.24)) { step -= 1 } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Spacer()
            Button {
                if step < 2 {
                    Motion.run(Motion.exit(0.32)) { step += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(step < 2 ? "下一步" : "开始使用")
                    .font(Type.text(Type.body, weight: .medium))
                    .foregroundStyle(step < 2 ? Color.primary : Color.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(step < 2 ? AnyShapeStyle(Ink.subtle) : AnyShapeStyle(Color.primary))
                    )
                    .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: step < 2 ? 0.5 : 0))
            }
            .buttonStyle(.plain)

            Button("跳过引导", action: finish)
                .buttonStyle(.plain)
                .font(Type.text(Type.caption))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 32)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onComplete?()
    }
}

// MARK: - ① 管线自演示

private struct PipelineStep: View {
    let revealed: Bool

    var body: some View {
        VStack(spacing: Metrics.xxxl) {
            VStack(spacing: Metrics.sm) {
                Text("实时语音转字幕")
                    .font(Type.text(40, weight: .medium))
                    .titleTracking(40)
                Text("Making speech more productive than ever before.")
                    .font(Type.text(Type.body))
                    .foregroundStyle(Ink.secondary)
            }
            .multilineTextAlignment(.center)
            .reveal(revealed, delay: 0)

            // 波形 → 识别 → 字幕 的实时演示（真动效，非静态重绘）。
            SpeechDemo()
                .frame(height: 132)
                .reveal(revealed, delay: 0.12)

            PipelineFlow(visible: revealed)
                .reveal(revealed, delay: 0.2)
        }
        .padding(.top, Metrics.xl)
    }
}

/// 演示：波形条 + 逐字打出 + 光标闪烁 + 字幕胶囊淡入。
private struct SpeechDemo: View {
    private let phrase = "现在开始评审这一版设计。"
    @State private var typed = ""
    @State private var caretOn = true
    @State private var showCaption = false

    var body: some View {
        VStack(spacing: Metrics.xl) {
            WaveformBars()
                .frame(height: 34)
                .frame(maxWidth: 220)

            HStack(spacing: 2) {
                Text(typed)
                    .font(Type.text(Type.emphasis))
                    .foregroundStyle(Color.primary)
                Rectangle()
                    .fill(Ink.secondary)
                    .frame(width: 2, height: 16)
                    .opacity(caretOn ? 1 : 0)
            }
            .frame(height: 22, alignment: .center)
            .onAppear {
                // 光标闪烁：1.06s 一循环（站点 input-caret-blink 的节奏）。
                guard !MotionPrefs.shared.reduceMotion else { caretOn = true; return }
                withAnimation(.linear(duration: 0.53).repeatForever(autoreverses: true)) {
                    caretOn = false
                }
            }

            if showCaption {
                Text("Now let's review this design.")
                    .font(Type.text(Type.caption, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Corner.rect(Corner.pill).fill(Color.black.opacity(0.82)))
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .task { await run() }
    }

    @MainActor
    private func run() async {
        // Task.sleep 被取消只是提前返回，必须自己检查取消——
        // 否则页面已经切走，打字机还会继续往已销毁的视图上追加字符。
        for ch in phrase {
            try? await Task.sleep(for: .milliseconds(90))
            if Task.isCancelled { return }
            typed.append(ch)
        }
        try? await Task.sleep(for: .milliseconds(260))
        guard !Task.isCancelled else { return }
        Motion.run(Motion.exit(0.32)) { showCaption = true }
    }
}

/// 6 根波形条：Canvas 自绘 + TimelineView 驱动（不重建视图树）。
private struct WaveformBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: MotionPrefs.shared.reduceMotion)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let count = 6
                let barWidth: CGFloat = 3
                let gap = (size.width - CGFloat(count) * barWidth) / CGFloat(count - 1)
                for i in 0..<count {
                    let phase = t * 2.4 + Double(i) * 0.7
                    let amp = MotionPrefs.shared.reduceMotion ? 0.5 : (sin(phase) * 0.5 + 0.5)
                    let h = max(4, size.height * (0.25 + 0.75 * amp))
                    let rect = CGRect(
                        x: CGFloat(i) * (barWidth + gap),
                        y: (size.height - h) / 2,
                        width: barWidth,
                        height: h
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(Color.primary.opacity(0.78))
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 管线流程图：采集 → VAD → ASR → 翻译 → 渲染，45ms stagger 逐个淡入。
private struct PipelineFlow: View {
    let visible: Bool

    private struct Node {
        let icon: String
        let label: String
        let color: Color
    }

    private let nodes: [Node] = [
        Node(icon: "waveform", label: "采集", color: Ink.secondary),
        Node(icon: "waveform.badge.mic", label: "VAD", color: Palette.info),
        Node(icon: "brain", label: "ASR", color: Color.purple),
        Node(icon: "character.bubble", label: "翻译", color: Palette.ok),
        Node(icon: "captions.bubble", label: "渲染", color: Palette.live),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { idx, node in
                if idx > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Ink.secondary.opacity(0.4))
                        .padding(.horizontal, 8)
                        .opacity(visible ? 1 : 0)
                        .animation(Motion.anim(Motion.exit(0.3).delay(0.045 * Double(idx))), value: visible)
                }
                VStack(spacing: Metrics.sm) {
                    Image(systemName: node.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(node.color)
                    Text(node.label)
                        .font(Type.mono(Type.micro, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .fixedSize()          // 不让标签被同级的图标宽度压成「A…」
                }
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Corner.rect(Corner.card).fill(Ink.faint))
                .overlay(Corner.rect(Corner.card).strokeBorder(Ink.hairline, lineWidth: 0.5))
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 8)
                .animation(Motion.anim(Motion.exit(0.3).delay(0.045 * Double(idx))), value: visible)
            }
        }
    }
}

// MARK: - ② 权限与模型

private struct PermissionsStep: View {
    @State private var tick = Date()

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: Metrics.lg)]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.xl) {
            VStack(alignment: .leading, spacing: Metrics.sm) {
                Text("三项就绪就能开录")
                    .font(Type.text(Type.title, weight: .semibold))
                    .titleTracking(Type.title)
                Text("授权只在首次需要；未授予时录制入口会自动跳回这一步。")
                    .font(Type.text(Type.caption))
                    .foregroundStyle(Ink.secondary)
            }

            LazyVGrid(columns: columns, spacing: Metrics.lg) {
                PermissionRow(
                    title: "麦克风",
                    detail: "采集本地语音输入",
                    granted: micGranted,
                    actionTitle: "去授权",
                    action: { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                )
                PermissionRow(
                    title: "屏幕录制",
                    detail: "录制系统音频（会议声音）",
                    granted: screenGranted,
                    actionTitle: "去授权",
                    action: {
                        _ = PermissionGuidePanelController.shared.authorizeForRecording()
                    }
                )
                PermissionRow(
                    title: "识别模型",
                    detail: "本地转录所需，一次下载长期使用",
                    granted: modelReady,
                    actionTitle: "去下载",
                    action: { NotificationCenter.default.post(name: .showModelDownload, object: nil) }
                )
            }
        }
        // 授权状态在系统设置里变更后没有回调，用 1Hz 轻轮询刷新（只读三个布尔）。
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    private var micGranted: Bool {
        _ = tick
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var screenGranted: Bool {
        _ = tick
        return CGPreflightScreenCaptureAccess()
    }

    private var modelReady: Bool {
        _ = tick
        return TranscriptionService.modelExists()
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: Metrics.lg) {
            Circle()
                .fill(granted ? Palette.ok : Ink.active)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Type.text(Type.body, weight: .medium))
                Text(detail)
                    .font(Type.text(Type.micro))
                    .foregroundStyle(Ink.secondary)
            }
            Spacer()
            if granted {
                Text("已就绪")
                    .font(Type.mono(Type.micro, weight: .medium))
                    .foregroundStyle(Palette.ok)
                    .contentTransition(.opacity)
                    .animation(Motion.anim(Motion.standard(0.24)), value: granted)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, Metrics.lg)
        .frame(height: 56)
        .background(Corner.rect(Corner.card).fill(Ink.faint))
        .overlay(Corner.rect(Corner.card).strokeBorder(Ink.hairline, lineWidth: 0.5))
        .animation(Motion.anim(Motion.standard(0.24)), value: granted)
    }
}

// MARK: - ③ 开录路径

/// 开录路径（据 MenuBarController 的实际入口据实描述）：
/// 菜单栏状态项 → 「开始录制（选择应用）」→ 一体化浮层的选择应用流程；
/// 录制中同一项变为「结束录制」（finishRecording 收口保存）。
///
/// 此前这里画 ⌥R / ⌥Q 键帽：全仓没有任何 option 修饰的全局快捷键监听
///（菜单项 keyEquivalent 是 ⌘R / ⌘Q，且只在菜单展开时有效），文案与实现不符。
/// 不新增全局快捷键：那会引入辅助功能权限依赖。
private struct ShortcutStep: View {
    let revealed: Bool

    var body: some View {
        VStack(spacing: Metrics.xxxl) {
            VStack(spacing: Metrics.lg) {
                Text("随时开录")
                    .font(Type.text(Type.title, weight: .semibold))
                    .titleTracking(Type.title)
                Text("从菜单栏开录，或直接把音频拖进左侧列表。")
                    .font(Type.text(Type.caption))
                    .foregroundStyle(Ink.secondary)
            }

            VStack(spacing: Metrics.md) {
                ShortcutPathRow(symbol: "menubar.arrow.up.rectangle",
                                title: "菜单栏图标 → 开始录制（选择应用）",
                                detail: "选中要录的应用，字幕浮层随录制出现")
                ShortcutPathRow(symbol: "stop.circle",
                                title: "录制中再点同一项 → 结束录制",
                                detail: "自动保存音频并生成转录记录")
            }
            .opacity(revealed ? 1 : 0)

            Text("录制中的字幕会浮在屏幕顶部，可穿透、可缩放，也支持 OBS 采集。")
                .font(Type.text(Type.micro))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Metrics.xxxl)
    }
}

/// 真实操作路径行（图标 + 标题 + 说明），替代原先的键帽提示。
private struct ShortcutPathRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Metrics.md) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 26)
                .background(Corner.rect(Corner.small).fill(Ink.subtle))
                .overlay(Corner.rect(Corner.small).strokeBorder(Ink.ring, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Type.text(Type.caption, weight: .medium))
                    .foregroundStyle(Color.primary)
                Text(detail)
                    .font(Type.mono(Type.micro))
                    .foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 340, alignment: .leading)
    }
}

// MARK: - 入场工具

extension View {
    /// 统一入场：淡入 + 8pt 上移（stagger 由 delay 控制）。
    fileprivate func reveal(_ visible: Bool, delay: Double) -> some View {
        self.opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .animation(Motion.anim(Motion.exit(0.42).delay(delay)), value: visible)
    }
}

extension Notification.Name {
    /// 「请打开模型下载面板」——面板的状态由 ContentView 持有，引导页只发请求。
    static let showModelDownload = Notification.Name("SonicScribe.showModelDownload")
}
