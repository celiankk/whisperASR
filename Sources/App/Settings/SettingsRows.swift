import SwiftUI

// MARK: - 设置页共用行组件
//
// 原先 StatusRow / StatusLevel 是 SystemStatusSettingsPage 的 private 类型，
// 音频页另写了一套 PermissionRow，说明文字各页手写 .font(.caption)。
// 这里统一成一组组件，视觉规格走 DesignTokens（等宽状态词 + 低饱和语义点）。

/// 状态等级 → 语义色（集中页与各引擎节共用同一套含义）。
enum StatusLevel {
    case ok, warning, error, idle

    var color: Color {
        switch self {
        case .ok: return Palette.ok
        case .warning: return Palette.warn
        case .error: return Palette.danger
        case .idle: return Ink.secondary
        }
    }
}

/// 一行状态：前导语义点 + 标题 + 右侧等宽状态词。
///
/// 状态词用等宽小字（站点的 mono 标签用法）：状态文字长度/数字变化时
/// 右边界不抖，且与标题的正文字号形成层级差，不需要加粗或色块。
struct StatusRow: View {
    let title: String
    let text: String
    let level: StatusLevel
    /// 纯信息行可去掉前导点（避免满屏绿点）。
    var showDot: Bool = true

    var body: some View {
        HStack(spacing: Metrics.md) {
            if showDot {
                Circle()
                    .fill(level.color.opacity(level == .idle ? 0.55 : 0.9))
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(Type.text(Type.body))
            Spacer(minLength: Metrics.xl)
            Text(text)
                .font(Type.mono(Type.micro, weight: .medium))
                .foregroundStyle(level.color)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .animation(Motion.anim(Motion.standard(0.2)), value: text)
        .animation(Motion.anim(Motion.standard(0.2)), value: level == .ok)
    }
}

/// 条件提示：只在「用户此刻需要知道」时出现的说明。
///
/// 设置页原本有大量常驻 caption 解释（识别页 31 处、系统状态页 24 处），
/// 多数在状态正常时是纯噪音——它们改为带 tint 的条件行，正常态不渲染。
struct SettingsHint: View {
    let text: String
    var level: StatusLevel = .idle

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.sm) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(level.color)
            Text(text)
                .font(Type.text(Type.micro))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var symbol: String {
        switch level {
        case .ok: return "checkmark.circle"
        case .warning: return "exclamationmark.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return "info.circle"
        }
    }
}

/// 可折叠诊断区（默认收起）：引擎状态原文、debug 摘要这类排障信息
/// 不该和可操作项抢位置，但也不能没有入口。
struct DiagnosticsDisclosure<Content: View>: View {
    let title: String
    var content: () -> Content
    @State private var expanded = false

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sm) {
            Button {
                Motion.run(Motion.standard(0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(title)
                        .font(Type.mono(Type.micro))
                        .tracking(Type.labelTracking)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Ink.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: Metrics.xs) {
                    content()
                }
                .transition(.opacity)
            }
        }
    }
}

/// 结果徽标：一行内联的「符号 + 等宽状态文字」，语义色走 StatusLevel。
///
/// 各设置页原本手写 `Label(...).foregroundStyle(.green).font(.caption)`
/// 十处（API 服务器运行中、备份成功/失败、密钥校验、保存确认、VAD 已启用…），
/// 字号/色值/符号各不相同。统一到这里，正常态与异常态的视觉重量才一致。
struct StatusBadge: View {
    let text: String
    var level: StatusLevel = .ok
    var lineLimit: Int? = 2

    /// 无标签首参：调用点保持 `StatusBadge("已启用", level: .ok)` 的可读性。
    init(_ text: String, level: StatusLevel = .ok, lineLimit: Int? = 2) {
        self.text = text
        self.level = level
        self.lineLimit = lineLimit
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(text)
                .font(Type.mono(Type.micro, weight: .medium))
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(level.color)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Motion.anim(Motion.standard(0.2)), value: text)
    }

    private var symbol: String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .idle: return "circle"
        }
    }
}

/// 诊断用的等宽原文行（引擎 debug 串、日志片段）。
struct MonoDiagnostic: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Type.mono(Type.micro))
            .foregroundStyle(Ink.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
