import Foundation
import Speech
import AVFoundation
import AppKit
import Observation

// MARK: - Apple Speech 状态（AppleSpeechStatus）
//
// macOS 26 原生 Speech Framework（SpeechAnalyzer / SpeechTranscriber）状态层：
// - 引擎状态机（idle → initializing → loadingLanguage → listening → …）；
// - 权限封装：Speech Recognition 授权（识别本身不使用 SFSpeechRecognizer；
//   授权 API 仅有 SFSpeechRecognizer.requestAuthorization，故集中于此）+ 麦克风；
// - 运行时能力快照（@Observable 单例，View 只读）。
//
// 本地识别（on-device）判定：新 Speech 框架没有 on-device 能力 API
// （仅旧 SFSpeechRecognizer 有 supportsOnDeviceRecognition），
// 以「授权 + Transcriber 可用 + 语言可解析 + 语言包已安装」综合判定，
// 不可用时给出明确原因（本地可用 / 需要下载资源 / 系统不支持 / 权限）。

/// Apple Speech 引擎状态机（设置页展示用）。
enum AppleSpeechEngineState: String {
    case idle = "Idle"
    case initializing = "Initializing"
    case loadingLanguage = "Loading Language"
    case listening = "Listening"
    case processing = "Processing"
    case paused = "Paused"
    case unavailable = "Unavailable"
    case permissionDenied = "Permission Denied"
    case error = "Error"
}

/// 语言资源状态（AppleLanguageManager 查询结果）。
enum AppleLanguageResourceState: String {
    case installed = "Installed"
    case available = "Available"
    case needDownload = "Need Download"
    case unavailable = "Unavailable"
}

/// AppleSpeechDebug：初始化 / 语言加载 / Audio Buffer / Partial / Final / 延迟 / 错误。
struct AppleSpeechDebug {
    var initDuration: TimeInterval = 0          // start() 耗时
    var languageLoadDuration: TimeInterval = 0   // 语言资源加载耗时
    var bufferCount: Int = 0                     // 已喂入音频 buffer 数
    var recognitionLatency: TimeInterval = 0     // 平均识别延迟（append→结果）
    var partialCount: Int = 0                    // partial 次数
    var finalCount: Int = 0                      // final 次数
    var lastError: String? = nil                 // 最近一次错误

    var summary: String {
        "init=\(Int(initDuration * 1000))ms language=\(Int(languageLoadDuration * 1000))ms "
            + "buffers=\(bufferCount) latency=\(Int(recognitionLatency * 1000))ms "
            + "partial=\(partialCount) final=\(finalCount)"
            + (lastError.map { " error=\($0)" } ?? "")
    }
}

// MARK: - 权限

/// Speech Recognition 与 Microphone 权限统一封装。
/// Speech 框架授权入口仅有 SFSpeechRecognizer.requestAuthorization（无替代 API），
/// 识别实现（SpeechAnalyzer / SpeechTranscriber）不使用 SFSpeechRecognizer。
enum AppleSpeechPermission {
    enum SpeechAuth: String {
        case notDetermined = "未请求"
        case authorized = "已授权"
        case denied = "被拒绝"
        case restricted = "受限"
    }

    static var speechAuth: SpeechAuth {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }

    static var isSpeechAuthorized: Bool {
        speechAuth == .authorized
    }

    /// 确保语音识别已授权（notDetermined 时发起请求；不抛错）。
    /// requestAuthorization 在主线程调用（macOS 首次弹窗最稳妥）；
    /// 30s 超时保护：弹窗未出现 / 用户未操作时不永久挂起（录制循环依赖此返回值）。
    static func ensureSpeechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            // requestAuthorization 在主线程调用（macOS 首次弹窗最稳妥）。
            let status = await requestAuthorization(timeout: 30)
            return status == .authorized
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// 带超时的授权请求：超时返回 nil（不挂起调用方）。
    ///
    /// 不能用 withThrowingTaskGroup 竞速：requestAuthorization 的回调
    /// 不会响应 task cancellation，超时后 task group 仍会等待那个永远挂起的
    /// 子任务，所谓「30 秒超时保护」实际会永久挂起。这里用 AsyncStream：
    /// 超时任务调用 finish() 可立即让等待方拿到 nil。
    private static func requestAuthorization(
        timeout seconds: Double
    ) async -> SFSpeechRecognizerAuthorizationStatus? {
        let stream = AsyncStream<SFSpeechRecognizerAuthorizationStatus> { continuation in
            Task { @MainActor in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.yield(status)
                    continuation.finish()
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                continuation.finish()
            }
        }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    // MARK: - Microphone（保留：其他识别仍需要）

    static var microphoneAuth: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isMicrophoneAuthorized: Bool {
        microphoneAuth == .authorized
    }

    /// 打开系统权限设置（语音识别 / 麦克风）。
    /// 只缺麦克风权限时直接跳麦克风面板，否则跳语音识别面板
    /// （避免用户点了按钮却打开错误的隐私设置）。
    static func openSystemSettings() {
        let micDenied = microphoneAuth == .denied || microphoneAuth == .restricted
        let speechDenied = speechAuth == .denied || speechAuth == .restricted
        let pane = (micDenied && !speechDenied) ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 能力快照

/// Apple Speech 运行时能力快照（启动 / 进页面 / 语言变化时 refresh）。
@Observable
final class AppleSpeechStatus {
    static let shared = AppleSpeechStatus()

    /// 本地识别能力细分（失败必须显示原因）。
    enum OfflineState: String {
        case available = "本地可用"
        case needResource = "需要下载资源"
        case systemUnsupported = "系统不支持"
        case permissionDenied = "权限被拒绝"
        case notDetermined = "未授权"
    }

    /// 授权状态。
    private(set) var speechAuth: AppleSpeechPermission.SpeechAuth = .notDetermined
    /// 服务可用（已授权 + Transcriber 可用 + 语言可解析）。
    private(set) var serviceAvailable = false
    /// 当前选择语言（如 zh-CN）。
    private(set) var currentLocale = ""
    /// 当前语言语言包已安装。
    private(set) var localeSupported = false
    /// 本地（on-device）识别能力状态。
    private(set) var offlineState: OfflineState = .notDetermined
    /// 本地识别不可用时的具体原因。
    private(set) var offlineReason: String? = nil
    /// 本机已安装的识别语言数量。
    private(set) var installedLocaleCount = 0

    private init() {
        // 系统语言变化：重新检测（不轮询）。
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    private let refreshLock = NSLock()
    private var refreshing = false

    /// 全量检测（防并发）。
    func refresh() async {
        refreshLock.lock()
        guard !refreshing else {
            refreshLock.unlock()
            return
        }
        refreshing = true
        refreshLock.unlock()
        defer { refreshLock.lock(); refreshing = false; refreshLock.unlock() }

        switch AppleSpeechPermission.speechAuth {
        case .authorized: speechAuth = .authorized
        case .denied: speechAuth = .denied
        case .restricted: speechAuth = .restricted
        case .notDetermined: speechAuth = .notDetermined
        @unknown default: speechAuth = .restricted
        }

        // 已安装语言（本机可直接离线使用；不含"支持但未下载/需要下载"）。
        let installed = await AppleLanguageManager.shared.installedLanguages()
        installedLocaleCount = installed.count
        currentLocale = AppleSpeechManager.localeIdentifier
        // 按规范键比较：配置里可能是 zh-CN，Apple 返回的是 zh_CN。
        localeSupported = installed.contains {
            AppleLanguageManager.isSameLocale($0.identifier, currentLocale)
        }

        // 服务可用：已授权 + 新 Speech 框架能力（Transcriber 可用 + 语言可解析）。
        var localeResolvable = false
        if #available(macOS 26, *) {
            let resolved = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: currentLocale))
            localeResolvable = SpeechTranscriber.isAvailable && resolved != nil
        }
        serviceAvailable = speechAuth == .authorized && localeResolvable

        // 本地识别细分状态（失败必须显示原因）。
        switch speechAuth {
        case .notDetermined:
            offlineState = .notDetermined
            offlineReason = "首次使用 Apple Speech 时请求语音识别授权"
        case .denied, .restricted:
            offlineState = .permissionDenied
            offlineReason = "语音识别权限被拒绝（系统设置 → 隐私与安全性 → 语音识别）"
        case .authorized:
            if !localeResolvable {
                offlineState = .systemUnsupported
                offlineReason = "当前系统不支持语音识别或语言不受支持（需要 macOS 26+）"
            } else if !localeSupported {
                offlineState = .needResource
                offlineReason = "语言资源缺失（\(currentLocale)），启动时自动下载"
            } else {
                offlineState = .available
                offlineReason = nil
            }
        @unknown default:
            offlineState = .permissionDenied
            offlineReason = "未知授权状态"
        }

        AppLogger.shared.log(
            .asr,
            "AppleSpeechDebug: auth=\(speechAuth.rawValue) installedLocales=\(installedLocaleCount) "
                + "locale=\(currentLocale) service=\(serviceAvailable) "
                + "offline=\(offlineState.rawValue)"
                + (offlineReason.map { " reason=\($0)" } ?? "")
        )
    }
}
