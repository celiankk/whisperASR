import Foundation

// MARK: - 运行调度中心（AppRuntimeManager）
//
// AppState 拆分的一部分：运行时业务编排，AppState 只保留页面状态。
//
//   AppState（页面状态 / 全局配置引用 / 用户界面状态）
//        ↓ 委托
//   AppRuntimeManager（运行调度中心）
//        ├── RecognitionManager（ASR 启动/停止、识别循环、健康检查）
//        ├── TranslationManager（翻译队列、Provider 调用、API 请求管理）
//        ├── SubtitleManager（partial/final 字幕、字幕缓存、生命周期）
//        ├── TranscriptionService（引擎门面 → ASR Provider）
//        └── APIServer（本地 OpenAI 兼容接口，复用同一 service）
//
// 模型下载/选择（ModelManager）与系统监控（SystemMonitor）为独立组件，
// 不在此编排内。

final class AppRuntimeManager: @unchecked Sendable {
    /// 转录引擎门面（文件转录 / 实时转录 / 模型生命周期统一入口）。
    let service = TranscriptionService()
    /// 实时识别管理器（识别循环 / 健康检查 / 自动保存）。
    let recognition: RecognitionManager
    /// 翻译管理器（句尾翻译队列 / 批量翻译 / 降级）。
    let translation: TranslationManager
    /// 字幕管理器（partial/final 字幕缓存 / 生命周期）。
    let subtitle: SubtitleManager

    init() {
        subtitle = SubtitleManager()
        translation = TranslationManager()
        recognition = RecognitionManager(
            service: service,
            subtitleManager: subtitle,
            translationManager: translation
        )
    }

    /// 注入 AppState（弱引用：各管理器回写 UI 状态）。
    /// App 启动时由 AppState.init 调用一次。
    func attach(appState: AppState) {
        recognition.attach(appState: appState)
        translation.appState = appState
        attachAPIServer()
    }

    /// 把共享 TranscriptionService 挂到本地 OpenAI 兼容 API 服务器，
    /// 用户启用时启动服务。
    func attachAPIServer() {
        Task { @MainActor [service] in
            APIServer.shared.attach(service: service)
            if UserDefaults.standard.bool(forKey: APIServer.enabledKey) {
                APIServer.shared.start()
            }
        }
    }

    // MARK: - 实时会话编排

    /// 开始实时转录（FloatingLetter 录制流程调用）。
    func startLive(recorder: AudioRecorder) {
        recognition.startLive(recorder: recorder)
    }

    /// 结束实时转录（录音结束时调用）。
    func stopLive() {
        recognition.stopLive()
    }

    // MARK: - 退出

    /// 应用退出：取消全部后台任务（ASR / 翻译 / 健康检查）、释放模型与推理资源。
    func shutdown() {
        recognition.stopLive()
        translation.cancelAll()
        service.shutdown()
    }
}
