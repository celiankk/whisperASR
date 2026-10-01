import SwiftUI

// MARK: - 管线延迟仪表盘（VoidZero 风格）
//
// 设计语言（voidzero.dev）：大 monospaced 数字、`//` 代码风标签、
// 极简开发者美学。嵌入系统状态页，1s 自动刷新。
//
// 布局：横向卡片行，每张卡片 = 一个管线阶段的实时延迟：
//   // 端到端    // 翻译往返    // CPU     // 内存
//   342ms        187ms         12%       182MB
//
// 颜色阈值：< 500ms 绿 / 500–2000ms 橙 / > 2000ms 红。

// MARK: 延迟阈值

private enum LatencyLevel {
    case good, warn, bad, idle

    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .idle: return Color.secondary
        }
    }

    static func forMs(_ ms: Double) -> LatencyLevel {
        if ms <= 0 { return .idle }
        if ms < 500 { return .good }
        if ms < 2000 { return .warn }
        return .bad
    }
}

// MARK: 仪表盘

struct LatencyDashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioRecorder.self) private var recorder
    /// 共享采样器（生命周期由系统状态页 start/stop）。此前这里自己
    /// `SystemMonitor()` 新建实例却从不 start()，采样循环没跑 →
    /// cpuUsage/memoryBytes 恒为 0：CPU 卡显示 0%、内存卡显示「—」。
    @State private var monitor = SystemMonitor.shared
    @State private var onlineASRStats = OnlineASRStats.shared
    @State private var snapshot = PipelineLatencyStore.LatencyData()
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 14) {
            // 标题行。
            HStack(spacing: 8) {
                Text("//")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                Text("PIPELINE LATENCY")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Spacer()
                Text(isLive ? "● LIVE" : "○ IDLE")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(isLive ? Color.green : Color.secondary.opacity(0.5))
            }

            // 卡片行。
            HStack(spacing: 12) {
                LatencyCard(
                    label: "端到端",
                    value: snapshot.displayAvgMs > 0
                        ? "\(Int(snapshot.displayAvgMs))" : "—",
                    unit: "ms",
                    level: .forMs(snapshot.displayAvgMs),
                    sub: subText(snapshot.displayMs, avg: snapshot.displayAvgMs))

                LatencyCard(
                    label: "翻译往返",
                    value: snapshot.translateAvgMs > 0
                        ? "\(Int(snapshot.translateAvgMs))" : "—",
                    unit: "ms",
                    level: .forMs(snapshot.translateAvgMs),
                    sub: subText(snapshot.translateMs, avg: snapshot.translateAvgMs))

                LatencyCard(
                    label: "ASR 响应",
                    value: asrDisplay,
                    unit: "ms",
                    level: asrLevel,
                    sub: asrSub)

                LatencyCard(
                    label: "CPU",
                    value: "\(Int(monitor.cpuUsage * 100))",
                    unit: "%",
                    level: monitor.cpuUsage > 0.8 ? .bad
                        : (monitor.cpuUsage > 0.5 ? .warn : .good),
                    sub: "全机")

                LatencyCard(
                    label: "内存",
                    value: monitor.memoryBytes > 0
                        ? "\(Int(monitor.memoryBytes / 1024 / 1024))" : "—",
                    unit: "MB",
                    level: .good,
                    sub: "常驻")
            }
        }
        .onAppear {
            // start() 内部有 timer == nil 守卫，重复调用安全：仪表盘若被嵌到
            // 别的页面，不能依赖宿主页面替它启动。
            monitor.start()
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
            // 采样器与系统状态页共享，当前唯一宿主就是它：停止交给
            // SystemStatusSettingsView.onDisappear，这里不重复 stop。
        }
    }

    // MARK: 刷新（从共享 store 拉快照）

    private func refresh() {
        snapshot = PipelineLatencyStore.shared.snapshot
        onlineASRStats = OnlineASRStats.shared
    }

    // MARK: 派生

    private var isLive: Bool {
        recorder.state == .recording
    }

    private var asrDisplay: String {
        if onlineASRStats.totalRequests > 0 {
            let ms = onlineASRStats.averageResponseTime * 1000
            return "\(Int(ms))"
        }
        if snapshot.asrAvgMs > 0 { return "\(Int(snapshot.asrAvgMs))" }
        return "—"
    }

    private var asrLevel: LatencyLevel {
        if onlineASRStats.totalRequests > 0 {
            return .forMs(onlineASRStats.averageResponseTime * 1000)
        }
        return .forMs(snapshot.asrAvgMs)
    }

    private var asrSub: String {
        if onlineASRStats.totalRequests > 0 { return "online" }
        return "local"
    }

    private func subText(_ latest: Double, avg: Double) -> String {
        guard latest > 0, avg > 0 else { return "" }
        return "latest \(Int(latest))"
    }
}

// MARK: 延迟卡片

/// VoidZero 风格指标卡：大 monospaced 数字 + 代码风标签 + 颜色阈值。
private struct LatencyCard: View {
    let label: String
    let value: String
    let unit: String
    let level: LatencyLevel
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("// \(label)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.5))

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(level.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !sub.isEmpty {
                Text(sub)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}
