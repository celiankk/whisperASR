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
    /// 应用列表首次加载为空时的自动重试次数（上限 2 次，防死循环）。
    private var appListRetryCount = 0
    private var appListRetryTask: Task<Void, Never>?

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
        appListRetryTask?.cancel()
        appListRetryTask = nil
        viewModel.teardown()
    }

    /// 仅解除观察，不销毁 ViewModel 定时器状态。
    /// 用于宿主“重复 present 刷新绑定”的场景——复用同一个 VM 时不能把它
    /// 标记为 torn down，否则 5 秒自动隐藏计时器会永久失效。
    func detach() {
        observationTask?.cancel()
        observationTask = nil
        appListRetryTask?.cancel()
        appListRetryTask = nil
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

        // ---- 选择应用阶段动作 ----
        viewModel.onStartAppSelection = { [weak self] in
            guard let self else { return }
            self.appListRetryCount = 0
            self.recorder.loadAvailableApps()
        }
        viewModel.onCancelAppSelection = { [weak self] in
            guard let self else { return }
            self.recorder.state = .idle
            self.recorder.selectedApp = nil
            self.onMinimize?()
        }
        viewModel.onSelectApp = { [weak self] bundleID in
            guard let self else { return }
            self.recorder.selectedApp = self.recorder.availableApps
                .first { $0.bundleIdentifier == bundleID }
        }
        viewModel.onConfirmRecording = { [weak self] in
            guard let self, let app = self.recorder.selectedApp else { return }
            self.recorder.startRecording(app: app)
            // 一体化浮层直接承担实时字幕职责：确认录制后立即启动实时转录。
            // （旧流程由 RecordingView.onAppear 负责，该窗口已彻底移除。）
            if self.appState.enableLiveTranscription, !self.appState.isLiveTranscribing {
                self.appState.startLiveTranscription(recorder: self.recorder)
            }
        }
        viewModel.onRetryLoadApps = { [weak self] in
            guard let self else { return }
            self.recorder.loadAvailableApps()
        }
        viewModel.onOpenSystemSettings = { [weak self] in
            guard let self else { return }
            self.recorder.openSystemPreferences()
        }
        viewModel.onToggleIncludeMicrophone = { [weak self] mic in
            guard let self else { return }
            self.recorder.includeMicrophone = mic
        }
        viewModel.onToggleLiveTranscription = { [weak self] enabled in
            guard let self else { return }
            self.appState.enableLiveTranscription = enabled
            if !enabled { self.appState.setTranslationMode(.off) }
        }
        viewModel.onToggleLiveTranslation = { [weak self] enabled in
            guard let self else { return }
            self.appState.setTranslationMode(enabled ? .onlineAPI : .off)
            UserDefaults.standard.set(enabled, forKey: "liveTranslationPref")
        }
        viewModel.onLiveModelSelectionChanged = { fileName in
            ModelManager.shared.liveFileName = fileName
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
                _ = self.appState.maxSubtitleLines
                _ = self.appState.isLiveTranscribing
                _ = self.appState.enableLiveTranscription
                _ = self.appState.enableLiveTranslation
                _ = self.recorder.state
                _ = self.recorder.selectedApp
                _ = self.recorder.recordingDuration
                _ = self.recorder.availableApps
                _ = self.recorder.error
                _ = self.recorder.includeMicrophone
                _ = ModelManager.shared.liveFileName
                _ = ModelManager.shared.downloadedFileNames
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
        // 字幕：末段为流式临时句（interim），其余为完整句（final）进入队列。
        let segments = appState.liveSegments
        let translations = appState.liveTranslatedSegments
        let interimIndex = segments.count - 1

        let interimSegmentText = interimIndex >= 0
            ? (segments[interimIndex].text.trimmingCharacters(in: .whitespacesAndNewlines))
            : ""
        let interimTranslation: String? = {
            guard appState.enableLiveTranslation,
                  interimIndex >= 0,
                  interimIndex < translations.count else { return nil }
            let text = translations[interimIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }()

        // 完整句队列：末段之前的段落视为已结束。
        let finalLines: [FloatingLetterViewModel.SubtitleLine] = (0..<max(0, segments.count - 1)).compactMap { index in
            let text = segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let translation: String? = {
                guard appState.enableLiveTranslation, index < translations.count else { return nil }
                let t = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }()
            return FloatingLetterViewModel.SubtitleLine(id: "seg-\(index)", text: text, translation: translation)
        }
        viewModel.maxLines = appState.maxSubtitleLines
        let isPlaying = (recorder.state == .recording || recorder.state == .saving)
            && appState.isLiveTranscribing
        viewModel.updateSubtitleState(
            final: finalLines,
            interimText: interimSegmentText,
            interimTranslation: interimTranslation,
            isPlaying: isPlaying
        )

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

        // 选择应用阶段状态。
        switch recorder.state {
        case .idle, .loading:
            if viewModel.isSelectingApp {
                viewModel.appListPhase = .loading
            }
        case .ready:
            viewModel.appListPhase = .ready
            viewModel.appListError = recorder.error
            viewModel.availableApps = sortedAvailableApps()
            viewModel.selectedAppID = recorder.selectedApp?.bundleIdentifier
        case .permissionDenied:
            viewModel.appListPhase = .permissionDenied
            viewModel.appListError = recorder.error
        default:
            break
        }

        // 录制选项（与原选择窗口一致）。
        viewModel.includeMicrophone = recorder.includeMicrophone
        viewModel.enableLiveTranscription = appState.enableLiveTranscription
        viewModel.enableLiveTranslation = appState.enableLiveTranslation
        viewModel.liveModelOptions = ModelManager.shared.downloadedModels.map {
            FloatingLetterViewModel.FloatingModelOption(id: $0.fileName, name: $0.displayName)
        }
        viewModel.liveModelSelection = ModelManager.shared.liveFileName

        // 录制真正开始后退出选择模式。
        if recorder.state == .recording || recorder.state == .saving {
            if viewModel.isSelectingApp {
                viewModel.isSelectingApp = false
            }
            viewModel.appListPhase = .idle
            appListRetryTask?.cancel()
        }

        // 首次打开应用列表为空的兜底：短暂延迟后自动重载（最多 2 次）。
        if viewModel.isSelectingApp,
           recorder.state == .ready,
           viewModel.availableApps.isEmpty,
           recorder.error == nil {
            scheduleAppListRetry()
        } else {
            appListRetryTask?.cancel()
        }
    }

    private func scheduleAppListRetry() {
        appListRetryTask?.cancel()
        guard appListRetryCount < 2 else { return }
        appListRetryCount += 1
        appListRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self,
                  self.viewModel.isSelectingApp,
                  self.viewModel.availableApps.isEmpty,
                  self.recorder.state == .ready || self.recorder.state == .idle else { return }
            self.recorder.loadAvailableApps()
        }
    }

    /// 按“最近使用优先、其余按名称”排序应用列表。
    private func sortedAvailableApps() -> [FloatingLetterViewModel.FloatingApp] {
        let recent = recorder.recentAppBundleIDs
        return recorder.availableApps
            .map {
                FloatingLetterViewModel.FloatingApp(
                    id: $0.bundleIdentifier,
                    name: $0.applicationName,
                    processID: $0.processID
                )
            }
            .sorted { a, b in
                let ai = recent.firstIndex(of: a.id)
                let bi = recent.firstIndex(of: b.id)
                switch (ai, bi) {
                case let (.some(x), .some(y)): return x < y
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
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

#if DEBUG
    /// 自检用：读取当前 ViewModel（release 构建不含）。
    var debugViewModel: FloatingLetterViewModel? { viewModel }
#endif

    /// 展示浮层（已展示时刷新业务绑定）。
    func present(
        appState: AppState,
        recorder: AudioRecorder,
        onMinimize: (() -> Void)? = nil
    ) {
        if let viewModel {
            binder?.detach()
            binder = FloatingLetterOverlayBinder(
                viewModel: viewModel,
                appState: appState,
                recorder: recorder,
                onMinimize: onMinimize
            )
            FloatingLetterOverlayController.shared.present(viewModel: viewModel)
            wirePickerBinding(for: viewModel)
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

        // 选择应用弹窗与字幕浮层解耦：由宿主统一接线。
        wirePickerBinding(for: viewModel)
    }

    /// 把“选择应用模式”切换接到独立弹窗的展示/收起。
    private func wirePickerBinding(for viewModel: FloatingLetterViewModel) {
        viewModel.onSelectingChanged = { [weak self, weak viewModel] selecting in
            Task { @MainActor in
                guard let self, let viewModel, self.viewModel === viewModel else { return }
                if selecting {
                    FloatingAppPickerController.shared.present(viewModel: viewModel)
                } else {
                    FloatingAppPickerController.shared.dismiss()
                }
            }
        }
    }

    /// “开始录制”入口：展示一体化浮层并直接进入选择应用模式。
    func startRecordingFlow(
        appState: AppState,
        recorder: AudioRecorder,
        onMinimize: (() -> Void)? = nil
    ) {
        present(appState: appState, recorder: recorder, onMinimize: onMinimize)
        viewModel?.startAppSelection()
    }

    /// 销毁浮层并清理全部资源（观察、监听、定时器）。
    func dismiss() {
        binder?.stop()
        binder = nil
        viewModel = nil
        FloatingLetterOverlayController.shared.dismiss()
        FloatingAppPickerController.shared.dismiss()
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
