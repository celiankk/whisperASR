import Foundation
import Observation
import Darwin

// MARK: - 字幕引擎生命周期与稳定性（SubtitleEngine）
//
// 统一管理实时字幕链路的生命周期与健康度：
// - SubtitleUpdateScheduler：UI 刷新节流（100~200ms 批量，不做 token 级刷新）；
// - SubtitleRingBuffer：固定容量缓存（超限丢最旧）；
// - PerformanceMonitor：内存 / 任务 / 缓冲 / 模型状态监控 + 异常检测；
// - DebugLogger：开发日志（启动/停止/异常/资源状态）；
// - 任务纪律：ASR 单任务、翻译单飞（已在 AppState 单槽 worker 实现），
//   停止时全部 cancel；禁止无限创建 async Task。

// MARK: - 固定容量环形缓冲

struct SubtitleRingBuffer<Element> {
    private(set) var items: [Element] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { items.count }

    /// 追加；超出容量删除最旧。
    mutating func append(_ element: Element) {
        items.append(element)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    mutating func removeAll() {
        items.removeAll()
    }
}

// MARK: - UI 刷新节流调度器

/// 合并同一节流窗口内的多次更新，只提交最后一次（150ms 批量刷新）。
@MainActor
final class SubtitleUpdateScheduler {
    private var pending: (() -> Void)?
    private var timer: Task<Void, Never>?
    let interval: TimeInterval

    init(interval: TimeInterval = 0.15) {
        self.interval = interval
    }

    func schedule(_ work: @escaping () -> Void) {
        pending = work
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.interval ?? 0.15))
            guard let self, !Task.isCancelled else { return }
            self.flush()
        }
    }

    private func flush() {
        timer = nil
        let work = pending
        pending = nil
        work?()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        pending = nil
    }
}

// MARK: - 开发日志
//
// 引擎日志统一汇入 AppLogger（.engine 分类）：单一环形缓冲，
// 避免多套日志缓冲并存导致的长运行内存增长。

final class DebugLogger {
    static let shared = DebugLogger()

    private init() {}

    func log(_ message: String) {
        AppLogger.shared.log(.engine, message)
    }

    var recentLogs: [String] { AppLogger.shared.recentLogs(category: .engine) }
}

// MARK: - 字幕历史记录（SubtitleHistoryManager）
//
// 历史记录独立于实时字幕状态（liveSegments / renderer 完全不共享数组）：
// 每句结束记录一次（时间 / 原文 / 翻译 / 语言），固定容量 200 条，
// 超限丢弃最旧——长时间运行内存恒定。UI 只读，不反向写入。

struct SubtitleHistoryEntry: Equatable {
    let time: Date
    let original: String
    let translation: String?
    let language: String
}

final class SubtitleHistoryManager {
    static let shared = SubtitleHistoryManager()

    /// 历史记录上限：超出丢弃最旧（环形窗口）。
    static let maxEntries = 200

    private var buffer = SubtitleRingBuffer<SubtitleHistoryEntry>(capacity: maxEntries)
    private let lock = NSLock()

    private init() {}

    /// 记录一条字幕历史；空原文忽略；与上一条原文完全相同视为 ASR 重复输出，跳过。
    func record(original: String, translation: String?, language: String) {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if buffer.items.last?.original == trimmed { return }
        buffer.append(
            SubtitleHistoryEntry(
                time: Date(),
                original: trimmed,
                translation: translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                language: language
            )
        )
    }

    /// 新会话开始时清空（与实时字幕生命周期对齐）。
    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    var recent: [SubtitleHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.items
    }
}

// MARK: - 性能监控

@Observable
final class PerformanceMonitor {
    private(set) var residentMemoryBytes: Int64 = 0
    private(set) var asrTaskCount = 0
    private(set) var translationQueueDepth = 0
    private(set) var subtitleBufferCount = 0
    private(set) var modelStatus = "idle"
    /// 最近 2 分钟内存增长（MB）；> 阈值视为异常。
    private(set) var memoryGrowthMB = 0.0
    private(set) var anomalyDetected = false

    private var memorySamples: [Double] = []
    private let growthThresholdMB = 80.0

    var residentMemoryMB: Double { Double(residentMemoryBytes) / 1_048_576 }

    /// 每个健康检查周期调用一次。
    func snapshot(asr: Int, translationQueue: Int, subtitleBuffers: Int, model: String) {
        residentMemoryBytes = Self.currentResidentBytes()
        asrTaskCount = asr
        translationQueueDepth = translationQueue
        subtitleBufferCount = subtitleBuffers
        modelStatus = model

        let mb = residentMemoryMB
        memorySamples.append(mb)
        if memorySamples.count > 24 { memorySamples.removeFirst() }
        if memorySamples.count >= 12 {
            let recent = memorySamples.suffix(6).reduce(0, +) / 6
            let older = memorySamples.prefix(6).reduce(0, +) / 6
            memoryGrowthMB = recent - older
            anomalyDetected = memoryGrowthMB > growthThresholdMB || translationQueue > 5
        } else {
            memoryGrowthMB = 0
            anomalyDetected = false
        }
    }

    func reset() {
        residentMemoryBytes = 0
        asrTaskCount = 0
        translationQueueDepth = 0
        subtitleBufferCount = 0
        modelStatus = "idle"
        memoryGrowthMB = 0
        anomalyDetected = false
        memorySamples.removeAll()
    }

    static func currentResidentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}

// MARK: - 字幕引擎（生命周期门面）

/// 实时字幕引擎：Start（启动全部任务）/ Stop（释放全部资源）/ Reset（清理状态）。
/// 实际 ASR 与翻译任务由 AppState 执行，引擎负责统一生命周期、
/// 健康度监控、日志与异常恢复信号；UI 刷新节流由桥接层持有调度器。
final class SubtitleEngine {
    static let shared = SubtitleEngine()

    let monitor = PerformanceMonitor()
    let logger = DebugLogger.shared

    private(set) var isRunning = false
    private var startDate: Date?

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startDate = Date()
        logger.log("Subtitle Engine Started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        startDate = nil
        logger.log("Subtitle Engine Stopped")
    }

    func reset() {
        monitor.reset()
        logger.log("Subtitle Engine Reset")
    }

    var uptime: TimeInterval {
        startDate.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// 健康检查：记录资源快照，发现异常返回 true（由调用方执行自动恢复）。
    @discardableResult
    func tick(asr: Int, translationQueue: Int, subtitleBuffers: Int, model: String) -> Bool {
        monitor.snapshot(
            asr: asr,
            translationQueue: translationQueue,
            subtitleBuffers: subtitleBuffers,
            model: model
        )
        if monitor.anomalyDetected {
            logger.log(
                "Anomaly: memoryGrowth=\(Int(monitor.memoryGrowthMB))MB "
                    + "asr=\(asr) translationQueue=\(translationQueue) "
                    + "buffers=\(subtitleBuffers) model=\(model)"
            )
            return true
        }
        return false
    }
}
