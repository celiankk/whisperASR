import Foundation

// MARK: - 统一日志系统（AppLogger）
//
// 分类日志门面：Window / ASR / Translation / Model / UI / Engine。
// - 固定容量环形缓冲（默认 1000 条），长时间运行内存不增长；
// - 线程安全（NSLock），任意线程/actor 可直接调用；
// - 同步输出到 stdout（开发与崩溃定位用）。
//
// 使用：AppLogger.shared.log(.window, "panel presented")

enum LogCategory: String, CaseIterable {
    case window = "Window"
    case asr = "ASR"
    case onlineASR = "OnlineASR"
    case translation = "Translation"
    case model = "Model"
    case ui = "UI"
    case engine = "Engine"
}

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private var buffer = SubtitleRingBuffer<String>(capacity: 1000)
    private let lock = NSLock()
    private let dateFormatter = DateFormatter()
    /// stdout 待写行（异步批量 flush：实时识别期每秒数十条日志，
    /// 逐条 print 到无缓冲重定向文件 = 每条一次 write syscall；
    /// 合并为 0.3s 一次批量写，ring buffer 仍同步立即可读）。
    private var pendingStdout: [String] = []
    private var flushScheduled = false

    private init() {
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ category: LogCategory, _ message: String) {
        // DateFormatter 非线程安全：格式化必须在锁内（ASR 后台线程 /
        // 翻译任务 / UI 线程并发 log 时锁外调用是数据竞争）。
        lock.lock()
        let line = "[\(category.rawValue)] \(dateFormatter.string(from: Date())) \(message)"
        buffer.append(line)
        pendingStdout.append(line)
        let needSchedule = !flushScheduled
        flushScheduled = needSchedule ? true : flushScheduled
        lock.unlock()
        if needSchedule {
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(300))
                Self.shared.flushNow()
            }
        }
    }

    /// 批量写出 pending 行（flush 调度器与退出路径共用）。
    func flushNow() {
        lock.lock()
        let lines = pendingStdout
        pendingStdout.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !lines.isEmpty else { return }
        print(lines.joined(separator: "\n"))
    }

    /// 最近日志（可选按分类过滤）。
    func recentLogs(category: LogCategory? = nil) -> [String] {
        lock.lock()
        let all = buffer.items
        lock.unlock()
        guard let category else { return all }
        let prefix = "[\(category.rawValue)]"
        return all.filter { $0.hasPrefix(prefix) }
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}

// MARK: - 统一错误管理（ErrorManager）
//
// 所有非致命错误（模型加载失败 / API 失败 / 网络失败 / ASR 失败）统一上报：
// - 记录分类日志（便于定位崩溃/卡顿/状态错误）；
// - userFacing 非空时通过 toastHandler 提示用户；
// - 绝不抛出、绝不导致 App 退出。

enum AppErrorDomain: String {
    case model = "Model"
    case api = "API"
    case network = "Network"
    case asr = "ASR"
    case onlineASR = "OnlineASR"
    case window = "Window"
}

final class ErrorManager {
    static let shared = ErrorManager()

    /// 由 AppState 在启动时注入：向用户展示非致命错误（toast）。
    /// 声明为 @MainActor @Sendable，保证任意线程上报时安全跳到主 actor。
    var toastHandler: (@MainActor @Sendable (String) -> Void)?

    private init() {}

    /// 上报错误：只记录 + 可选提示，不抛出。
    func report(
        _ domain: AppErrorDomain,
        _ error: Error? = nil,
        context: String,
        userFacing: String? = nil
    ) {
        let detail = error.map { " — \($0.localizedDescription)" } ?? ""
        let category: LogCategory
        switch domain {
        case .model: category = .model
        case .api, .network: category = .translation
        case .asr: category = .asr
        case .onlineASR: category = .onlineASR
        case .window: category = .window
        }
        AppLogger.shared.log(category, "ERROR \(context)\(detail)")
        if let userFacing, let toastHandler {
            Task { @MainActor in toastHandler(userFacing) }
        }
    }
}
