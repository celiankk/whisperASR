import Foundation
import Observation
import CoreGraphics

// MARK: - 悬浮字幕浮层 ViewModel
//
// 职责：
// 1. 持有浮层全部 UI 状态（字幕、录制状态、工具栏开关、紧凑模式）；
// 2. 管理“5 秒无操作自动隐藏”的倒计时 Timer；
// 3. 把按钮点击翻译成业务动作——动作本身通过闭包注入（由宿主/桥接层
//    绑定到 AppState、AudioRecorder 等业务对象），从而做到 UI 与业务分离。
//
// 本类不引用 AppState / AudioRecorder，可独立复制到任意 SwiftUI 工程。

@Observable
final class FloatingLetterViewModel {
    // MARK: 常量

    /// 鼠标 5 秒无任何操作后自动淡出隐藏。
    static let idleHideAfter: TimeInterval = 5

    // MARK: 字幕内容

    /// 当前字幕文本（业务层持续推入最新识别结果）。
    var subtitleText = ""
    /// 当前段落的译文（可选）。
    var translationText: String?
    /// 字幕文本是否显示（工具栏“字幕”开关，纯 UI 状态）。
    var subtitleTextVisible = true

    // MARK: 录制状态

    /// 是否正在录制（录制中才展示录制相关控件）。
    var isRecording = false
    /// 监听的软件名称。
    var recordingAppName = "未选择应用"
    /// 格式化后的录制时长（mm:ss）。
    var recordingDurationText = "00:00"

    // MARK: 工具栏状态

    /// 对话气泡：翻译是否暂停。
    var isTranslationPaused = false
    /// 眼睛：是否仅显示译文。
    var translationOnly = false
    /// 图钉：窗口置顶。
    var isPinned = false
    /// 缩放箭头：紧凑/展开模式。
    var isCompact = false
    /// 是否允许闲置自动隐藏（录制中可配置）。
    var autoHideEnabled = true

    // MARK: 样式（由设置页同步，保持旧设置项继续生效）

    /// 原文（主字幕）字号。
    var sourceFontSize: CGFloat = 17
    /// 译文字号。
    var translationFontSize: CGFloat = 13
    /// 边框不透明度。
    var borderOpacity: Double = 0.1

    // MARK: 业务动作（由宿主注入，实现 UI 与业务分离）

    var onToggleTranslationPause: (() -> Void)?
    var onToggleTranslationOnly: (() -> Void)?
    /// 字幕开关回调（携带新值，便于宿主同步业务状态）。
    var onToggleSubtitle: ((Bool) -> Void)?
    /// 置顶开关回调（携带新值）。
    var onTogglePin: ((Bool) -> Void)?
    var onCancelRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?
    /// 点击关闭按钮（控制器据此销毁窗口）。
    var onClose: (() -> Void)?
    /// 关闭后的业务回调（宿主据此持久化“已关闭”偏好等）。
    var onClosed: (() -> Void)?
    /// 倒计时超时回调（控制器据此执行淡出隐藏）。
    var onIdleTimeout: (() -> Void)?
    /// 紧凑/展开切换回调（控制器据此调整窗口尺寸）。
    var onCompactChanged: ((Bool) -> Void)?

    // MARK: 私有状态

    /// 闲置倒计时 Timer。用 @ObservationIgnored 标记，避免被 Observation
    /// 追踪（Timer 本身不是 UI 状态）。
    @ObservationIgnored private var idleTimer: Timer?
    /// teardown 后不再启动新的倒计时。
    @ObservationIgnored private var isTornDown = false

    init() {
#if DEBUG
        FloatingLetterLeakState.viewModelAlive += 1
#endif
    }

    deinit {
        // 兜底：ViewModel 销毁时主动 invalidate 定时器，防止内存泄漏。
        invalidateIdleTimer()
#if DEBUG
        FloatingLetterLeakState.viewModelAlive -= 1
        print("[FloatingLetter] ViewModel deinit, alive=\(FloatingLetterLeakState.viewModelAlive)")
#endif
    }

    // MARK: - 字幕展示逻辑

    /// 去除首尾空白后的译文；空字符串视为无译文。
    var nonEmptyTranslation: String? {
        guard let text = translationText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else { return nil }
        return text
    }

    /// 浮层中央实际展示的主字幕文本（含空状态占位）。
    var displayedSubtitleText: String {
        if translationOnly {
            if let translation = nonEmptyTranslation {
                return translation
            }
            return subtitleTextVisible ? "等待翻译…" : "字幕已隐藏"
        }
        if subtitleTextVisible {
            return subtitleText.isEmpty ? "字幕浮层已就绪" : subtitleText
        }
        return "字幕已隐藏"
    }

    // MARK: - 生命周期

    /// 视图出现：开始 5 秒倒计时。
    func viewDidAppear() {
        registerInteraction()
    }

    /// 视图销毁：主动 invalidate 定时器，防止内存泄漏。
    func viewDidDisappear() {
        invalidateIdleTimer()
    }

    /// 彻底清理（控制器销毁浮层时调用，幂等）。
    func teardown() {
        isTornDown = true
        invalidateIdleTimer()
    }

    // MARK: - 闲置自动隐藏计时器

    /// 任意交互（点击、鼠标移动、进入浮层）后调用，重置 5 秒倒计时。
    func registerInteraction() {
        resetIdleTimer()
    }

    private func resetIdleTimer() {
        invalidateIdleTimer()
        guard autoHideEnabled, !isTornDown else { return }
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleHideAfter,
            repeats: false
        ) { [weak self] _ in
            guard let self, !self.isTornDown else { return }
            self.onIdleTimeout?()
        }
    }

    /// 主动 invalidate 定时器（View 销毁、关闭浮层、deinit 时都会调用）。
    func invalidateIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - 工具栏动作
    //
    // 每个动作都会先 registerInteraction()，保证“点击浮层内任意控件
    // 重置 5 秒倒计时”。

    func toggleTranslationPause() {
        registerInteraction()
        onToggleTranslationPause?()
    }

    func toggleTranslationOnly() {
        registerInteraction()
        onToggleTranslationOnly?()
    }

    func toggleSubtitle() {
        registerInteraction()
        subtitleTextVisible.toggle()
        onToggleSubtitle?(subtitleTextVisible)
    }

    func togglePin() {
        registerInteraction()
        isPinned.toggle()
        onTogglePin?(isPinned)
    }

    func toggleCompact() {
        registerInteraction()
        isCompact.toggle()
        onCompactChanged?(isCompact)
    }

    func cancelRecording() {
        registerInteraction()
        onCancelRecording?()
    }

    func endRecording() {
        registerInteraction()
        onEndRecording?()
    }

    func close() {
        invalidateIdleTimer()
        onClose?()
        onClosed?()
    }

    // MARK: - 工具方法

    /// 秒数格式化为 mm:ss。
    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
