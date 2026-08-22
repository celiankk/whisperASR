import Foundation
import Darwin

// MARK: - ASR 看门狗（ASRWatchdog）— 子进程隔离方案·段 1
//
// 对标 LiveTranslate「ASR 子进程隔离：崩溃/超时自动重启 + 内存超阈值
// 自动回收」的进程内等价物（段 1；真·XPC 子进程隔离为段 2，见 HANDOFF）：
//
// 1. **内存超阈值回收**：周期采样进程常驻内存（phys_footprint，
//    与活动监视器一致口径）。引擎模型加载后偶发内存膨胀
//    （whisper ctx 泄漏 / Metal 缓冲累积），全部空闲且超阈值时
//    释放全部模型——下次使用懒加载回来（用户无感，等效"回收重启"）。
// 2. **超时重建**（挂接在 ASRManager 的 TimeoutError 路径）：
//    连续 2 次推理超时 → unloadLiveModel，下一轮 pass 懒加载重建
//    上下文——进程内回收可能死锁/损坏的推理上下文。
//
// 判定逻辑纯函数化（MemoryReclaimPolicy 可单测），采样与策略分离。

/// 进程常驻内存采样（phys_footprint：实际物理页占用，活动监视器口径）。
enum ProcessMemory {
    private static var flavor: task_flavor_t { task_flavor_t(TASK_VM_INFO) }

    static var footprintBytes: Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, flavor, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }
}

/// 内存回收判定策略（纯逻辑）。
struct MemoryReclaimPolicy {
    /// 绝对上限（字节）。默认 6GB（qwen Q8 模型本身 ~2.2GB + 系统余量）；
    /// 用户可配 asrMemoryCeilingMB（0 = 默认）。
    var ceilingBytes: Int64
    /// 触发冷却：回收后该时间内不重复触发（防 unload/load 抖动）。
    var cooldown: TimeInterval = 60
    /// 模型加载完成后的常驻基线（footprint 快照）。nil = 未记录，
    /// 退回绝对上限判定。相对制：基线 + deltaBytes（原生推理库长时
    /// 泄漏检测——绝对阈值对不同大小模型会误判/漏判）。
    var baselineBytes: Int64? = nil
    /// 基线之上的膨胀容许量（默认 2GB，对标上游实践）。
    var deltaBytes: Int64 = 2_000_000_000

    static var `default`: MemoryReclaimPolicy {
        let configuredMB = UserDefaults.standard.double(forKey: "asrMemoryCeilingMB")
        let bytes: Int64 = configuredMB > 0
            ? Int64(configuredMB * 1_000_000)
            : 6_000_000_000
        return .init(ceilingBytes: bytes)
    }

    /// 当前生效上限：显式配置的绝对上限优先；否则基线相对制
    ///（baseline + delta，与绝对下限 ceilingBytes 取小者——基线制
    /// 不应比绝对制更宽松）。
    var effectiveCeiling: Int64 {
        if UserDefaults.standard.double(forKey: "asrMemoryCeilingMB") > 0 {
            return ceilingBytes
        }
        if let baseline = baselineBytes {
            return min(baseline + deltaBytes, ceilingBytes)
        }
        return ceilingBytes
    }

    /// 是否应回收：超生效上限 && 全部空闲 && 冷却已过。
    func shouldReclaim(footprintBytes: Int64,
                       asrIdle: Bool,
                       transcriptionIdle: Bool,
                       lastReclaim: Date?,
                       now: Date = Date()) -> Bool {
        guard footprintBytes > 0, footprintBytes >= effectiveCeiling else { return false }
        guard asrIdle, transcriptionIdle else { return false }
        if let last = lastReclaim, now.timeIntervalSince(last) < cooldown {
            return false
        }
        return true
    }
}

/// 看门狗状态机（挂接 ASRManager 5 秒健康检查）。
@MainActor
final class ASRWatchdog {
    private(set) var lastReclaimAt: Date?
    private(set) var reclaimCount = 0
    private var policy: MemoryReclaimPolicy

    /// 模型加载完成后记录常驻基线（preloadLiveModel 成功点调用；
    /// 每次（重）加载都会刷新——泄漏检测相对的就是最新基线）。
    func recordBaseline() {
        policy.baselineBytes = ProcessMemory.footprintBytes
        AppLogger.shared.log(.asr,
            "Watchdog: baseline recorded at \(policy.baselineBytes.map { "\($0 / 1_000_000)MB" } ?? "-")")
    }

    /// nonisolated：允许在非隔离上下文构造（状态本身在 MainActor 方法中变更）。
    nonisolated init(policy: MemoryReclaimPolicy = .default) {
        self.policy = policy
    }

    /// 周期检查：满足回收条件返回 true（调用方执行释放并记录）。
    @discardableResult
    func checkIdleReclaim(asrIdle: Bool, transcriptionIdle: Bool) -> Bool {
        guard policy.shouldReclaim(
            footprintBytes: ProcessMemory.footprintBytes,
            asrIdle: asrIdle,
            transcriptionIdle: transcriptionIdle,
            lastReclaim: lastReclaimAt)
        else { return false }
        lastReclaimAt = Date()
        reclaimCount += 1
        AppLogger.shared.log(.asr,
            "Watchdog: idle memory reclaim #\(reclaimCount) — "
            + "footprint \(ProcessMemory.footprintBytes / 1_000_000)MB "
            + "≥ ceiling \(policy.ceilingBytes / 1_000_000)MB")
        return true
    }
}
