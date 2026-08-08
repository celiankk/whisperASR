import Foundation
import Network
import Observation

// MARK: - 系统监控（SystemMonitor）
//
// AppState 拆分的一部分：负责运行环境采样（2 秒周期）——
// - 后端状态（SubtitleEngine 是否运行）；
// - 网络状态（NWPathMonitor）；
// - CPU / 内存占用（全机 CPU、本进程常驻内存）。
//
// 由系统状态页持有（@State），页面 onAppear start / onDisappear stop。
// 翻译 API 状态由设置页的检测逻辑（按翻译方式异步探测）负责，不在本采样器。

@Observable
final class SystemMonitor {
    private(set) var cpuUsage: Double = 0      // 0...1，全机
    private(set) var memoryBytes: Int64 = 0    // 本进程常驻内存
    private(set) var networkOnline = true
    /// 字幕引擎（后端）是否运行（采样时读取）。
    private(set) var backendRunning = false

    private var lastTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private var pathMonitor: NWPathMonitor?
    private var timer: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        startNetworkMonitor()
        sample()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                self?.sample()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "whisperasr.settings.netmonitor"))
        pathMonitor = monitor
    }

    private func sample() {
        memoryBytes = PerformanceMonitor.currentResidentBytes()
        cpuUsage = sampleCPU()
        backendRunning = SubtitleEngine.shared.isRunning
    }

    /// 全机 CPU 使用率：两次采样间的 ticks 差分（首次返回 0）。
    private func sampleCPU() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &numCPUs, &cpuInfo, &numCpuInfo
        )
        guard kr == KERN_SUCCESS, let cpuInfo else { return cpuUsage }

        var user: UInt64 = 0, sys: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(numCPUs) {
            let base = stride * cpu
            user += UInt64(bitPattern: Int64(cpuInfo[base + Int(CPU_STATE_USER)]))
            sys += UInt64(bitPattern: Int64(cpuInfo[base + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(bitPattern: Int64(cpuInfo[base + Int(CPU_STATE_IDLE)]))
            nice += UInt64(bitPattern: Int64(cpuInfo[base + Int(CPU_STATE_NICE)]))
        }

        let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)

        guard let last = lastTicks else {
            lastTicks = (user, sys, idle, nice)
            return 0
        }
        lastTicks = (user, sys, idle, nice)

        let total = (user - last.user) + (sys - last.sys) + (idle - last.idle) + (nice - last.nice)
        guard total > 0 else { return 0 }
        return Double(total - (idle - last.idle)) / Double(total)
    }
}
