import Foundation
import Observation

// MARK: - 业务桥接层（WhisperASR 专用）
//
// 将 AppState / AudioRecorder 的状态持续推入 FloatingLetterViewModel，
// 并把 ViewModel 的用户动作回调绑定回业务方法。组件本身不依赖业务类型，
// 桥接层是唯一接触 AppState 的地方——替换或移除它即可在其他工程复用组件。

@MainActor
final class FloatingLetterOverlayBinder {
    private let viewModel: FloatingLetterViewModel
    private let appState: AppState
    private let recorder: AudioRecorder
    /// 结束/取消录制后收起关联窗口（如录制窗口）的闭包。
    private let onMinimize: (() -> Void)?
    private var observationTask: Task<Void, Never>?

    init(
        viewModel: FloatingLetterViewModel,
        appState: AppState,
        recorder: AudioRecorder,
        onMinimize: (() -> Void)?
    ) {
        self.viewModel = viewModel
        self.appState = appState
        self.recorder = recorder
        self.onMinimize = onMinimize

#if DEBUG
        FloatingLetterLeakState.binderAlive += 1
#endif
        wireActions()
        pushState()
        observeState()
    }

    deinit {
#if DEBUG
        FloatingLetterLeakState.binderAlive -= 1
        print("[FloatingLetter] Binder deinit, alive=\(FloatingLetterLeakState.binderAlive)")
#endif
    }

    /// 停止观察并销毁 ViewModel 定时器。
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        viewModel.teardown()
    }

    // MARK: 动作绑定（ViewModel 动作 → 业务方法）

    private func wireActions() {
        viewModel.onToggleTranslationPause = { [weak self] in
            guard let self else { return }
            self.appState.setLiveTranslationPaused(!self.appState.liveTranslationPaused)
        }

        viewModel.onToggleTranslationOnly = { [weak self] in
            guard let self else { return }
            self.appState.setLiveTranslationOnly(!self.appState.liveTranslationOnly)
        }

        viewModel.onTogglePin = { [weak self] pinned in
            guard let self else { return }
            self.appState.setRecordingAlwaysOnTop(pinned)
        }

        viewModel.onCancelRecording = { [weak self] in
            guard let self else { return }
            self.appState.stopLiveTranscription()
            self.recorder.cancelRecording()
            self.onMinimize?()
        }

        viewModel.onEndRecording = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.appState.finishRecording(recorder: self.recorder)
                self.onMinimize?()
            }
        }

    }

    // MARK: 状态观察（业务状态 → ViewModel 状态）

    private func observeState() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            withObservationTracking {
                _ = self.appState.liveSegments
                _ = self.appState.liveTranslatedSegments
                _ = self.appState.enableLiveTranslation
                _ = self.appState.liveTranslationPaused
                _ = self.appState.liveTranslationOnly
                _ = self.appState.recordingAlwaysOnTop
                _ = self.appState.subtitleOverlaySourceFontSize
                _ = self.appState.subtitleOverlayTranslationFontSize
                _ = self.appState.subtitleOverlayBorderOpacity
                _ = self.appState.floatingOverlayAutoHide
                _ = self.recorder.state
                _ = self.recorder.selectedApp
                _ = self.recorder.recordingDuration
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.pushState()
                    self.observeState()
                }
            }
        }
    }

    private func pushState() {
        // 字幕：取最后一个实时识别段落。
        viewModel.subtitleText = appState.liveSegments.last?.text ?? ""

        // 译文：与最后一段对应。
        if appState.enableLiveTranslation {
            let index = appState.liveSegments.count - 1
            if index >= 0, index < appState.liveTranslatedSegments.count {
                viewModel.translationText = appState.liveTranslatedSegments[index]
            } else {
                viewModel.translationText = nil
            }
        } else {
            viewModel.translationText = nil
        }

        // 工具栏状态。
        viewModel.isTranslationPaused = appState.liveTranslationPaused
        viewModel.translationOnly = appState.liveTranslationOnly
        viewModel.isPinned = appState.recordingAlwaysOnTop
        viewModel.sourceFontSize = CGFloat(appState.subtitleOverlaySourceFontSize)
        viewModel.translationFontSize = CGFloat(appState.subtitleOverlayTranslationFontSize)
        viewModel.borderOpacity = appState.subtitleOverlayBorderOpacity
        viewModel.autoHideEnabled = appState.floatingOverlayAutoHide

        // 录制状态：录制中/保存中才展示录制控件。
        viewModel.isRecording = recorder.state == .recording || recorder.state == .saving
        viewModel.recordingAppName = recorder.selectedApp?.applicationName ?? "未选择应用"
        viewModel.recordingDurationText = FloatingLetterViewModel.formatDuration(
            recorder.recordingDuration
        )
    }
}

// MARK: - 浮层宿主（应用内一键接入）
//
// 提供 present / dismiss / toggle 三个入口，持有 ViewModel 与桥接层。

@MainActor
final class FloatingLetterOverlayHost {
    static let shared = FloatingLetterOverlayHost()

    private var viewModel: FloatingLetterViewModel?
    private var binder: FloatingLetterOverlayBinder?

    private init() {}

    var isPresented: Bool {
        FloatingLetterOverlayController.shared.isVisible
    }

    /// 展示浮层（已展示时刷新业务绑定）。
    func present(
        appState: AppState,
        recorder: AudioRecorder,
        onMinimize: (() -> Void)? = nil
    ) {
        if let viewModel {
            binder?.stop()
            binder = FloatingLetterOverlayBinder(
                viewModel: viewModel,
                appState: appState,
                recorder: recorder,
                onMinimize: onMinimize
            )
            FloatingLetterOverlayController.shared.present(viewModel: viewModel)
            return
        }

        let viewModel = FloatingLetterViewModel()
        self.viewModel = viewModel
        binder = FloatingLetterOverlayBinder(
            viewModel: viewModel,
            appState: appState,
            recorder: recorder,
            onMinimize: onMinimize
        )
        FloatingLetterOverlayController.shared.present(viewModel: viewModel)
    }

    /// 销毁浮层并清理全部资源（观察、监听、定时器）。
    func dismiss() {
        binder?.stop()
        binder = nil
        viewModel = nil
        FloatingLetterOverlayController.shared.dismiss()
    }

    /// 切换显示/隐藏。
    func toggle(
        appState: AppState,
        recorder: AudioRecorder,
        onMinimize: (() -> Void)? = nil
    ) {
        if isPresented {
            dismiss()
        } else {
            present(appState: appState, recorder: recorder, onMinimize: onMinimize)
        }
    }
}

// MARK: - 最小接入示例（其他 SwiftUI 工程可整体照抄）
//
// 组件不依赖 WhisperASR 的业务类型，只要三步即可接入：
//
// 1. 创建 ViewModel 并注入业务动作：
//    let viewModel = FloatingLetterViewModel()
//    viewModel.onTogglePin = { pinned in MyApp.setWindowOnTop(pinned) }
//    viewModel.onCancelRecording = { MyRecorder.cancel() }
//    viewModel.onEndRecording = { Task { await MyRecorder.finish() } }
//    viewModel.onClosed = { MyApp.persistOverlayHidden() }   // 关闭后的业务回调
//
// 2. 业务状态变化时推入 ViewModel（没有 Observation 框架可用任意通知方式）：
//    viewModel.subtitleText = latestSegment.text
//    viewModel.isRecording = recorder.isRecording
//    viewModel.recordingDurationText = FloatingLetterViewModel.formatDuration(t)
//
// 3. 展示 / 关闭（窗口置顶、右上角定位、5 秒自动淡出均已内置）：
//    FloatingLetterOverlayController.shared.present(viewModel: viewModel)
//    FloatingLetterOverlayController.shared.dismiss()
//    （关闭按钮由控制器负责销毁窗口；如需持久化“已关闭”偏好，注入 onClosed。）
//
// WhisperASR 工程内直接使用宿主：
//    FloatingLetterOverlayHost.shared.toggle(
//        appState: appState,
//        recorder: audioRecorder
//    )
