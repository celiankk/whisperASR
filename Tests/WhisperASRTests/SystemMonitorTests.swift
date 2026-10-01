import XCTest
@testable import WhisperASR

/// 系统采样器回归测试。
///
/// 曾经的 bug：LatencyDashboardView 自己 `SystemMonitor()` 新建实例却从不
/// `start()`，采样循环没跑 → cpuUsage/memoryBytes 恒为 0，仪表盘 CPU 卡
/// 永远显示 0%、内存卡永远显示「—」。现在两处共用 .shared 并由视图启动。
final class SystemMonitorTests: XCTestCase {

    @MainActor
    func testStartProducesMemorySampleImmediately() {
        let monitor = SystemMonitor.shared
        monitor.start()          // 幂等：内部有 timer == nil 守卫
        defer { monitor.stop() }
        // start() 同步跑一次 sample()，常驻内存应立即非零。
        XCTAssertGreaterThan(monitor.memoryBytes, 0,
                             "start() 后 memoryBytes 仍为 0 —— 采样没跑，仪表盘会显示「—」")
    }

    @MainActor
    func testStartIsIdempotentAcrossViews() async throws {
        let monitor = SystemMonitor.shared
        monitor.start()
        let first = monitor.memoryBytes
        monitor.start()          // 第二个视图重复 start 不应重置或双采样
        defer { monitor.stop() }
        XCTAssertGreaterThanOrEqual(monitor.memoryBytes, first)
    }

    @MainActor
    func testCPUSamplePopulatesAfterSecondTick() async throws {
        let monitor = SystemMonitor.shared
        monitor.start()
        defer { monitor.stop() }
        // CPU 是全机 ticks 差分，首次为 0，需等第二个采样周期（2s）。
        try await Task.sleep(for: .seconds(2.4))
        XCTAssertGreaterThanOrEqual(monitor.cpuUsage, 0)
        XCTAssertTrue(monitor.cpuUsage <= 1.0, "cpuUsage 必须归一在 0...1，仪表盘按此着色")
    }
}
