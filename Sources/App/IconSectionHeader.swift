import SwiftUI

// MARK: - 设置页分组标签（IconSectionHeader）
//
// 参考 MacMixerF 控制页风格：分组标签为小号灰色文字，悬在卡片组上方，
// 无图标——视觉重量让位给页首大图标（SettingsPageHeader）。
// 保留 icon/color 参数（历史调用点兼容），渲染不再使用。

struct IconSectionHeader: View {
    let title: String
    let icon: String
    var iconColor: Color? = nil

    init(_ title: String, icon: String, color: Color? = nil) {
        self.title = title
        self.icon = icon
        self.iconColor = color
    }

    var body: some View {
        Text(title)
            .font(Type.mono(Type.label, weight: .medium))
            .tracking(Type.labelTracking)
            .foregroundStyle(Ink.secondary)
    }
}

// MARK: - 设置页页首（SettingsPageHeader）
//
// soft 变体：同色符号 + 同色 12% 底 + 发丝环（站点全站没有「白底块 + 彩色符号」
// 这种加底板的画法，也不给符号描白边）。

struct SettingsPageHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: Metrics.lg) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Corner.rect(Corner.small).fill(Ink.soft(color, 0.12)))
                .overlay(Corner.rect(Corner.small).strokeBorder(Ink.hairline, lineWidth: 0.5))
            Text(title)
                .font(Type.text(Type.display, weight: .semibold))
                .titleTracking(Type.display)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 设置分类导航行（SettingsNavRow）

/// 左栏导航行：露边圆角 + 激活点（站点的 sidebar-active-dot），
/// 不用系统 List 的满宽实心选中块。悬停淡出由父级驱动。
struct SettingsNavRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let dimmed: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Metrics.md) {
            ActiveDot(active: isSelected)
            Image(systemName: category.icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? category.iconColor : Ink.secondary)
                .frame(width: 18)
            Text(category.title)
                .font(Type.text(Type.body, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.md)
        .frame(height: 28)
        .background(
            Corner.rect(Corner.small)
                .fill(isSelected ? Ink.active : (hovering ? Ink.hover : .clear))
        )
        .contentShape(Corner.rect(Corner.small))
        .opacity(dimmed ? Ink.dimmedSibling : 1)
        .motionAnimation(Motion.standard(0.18), value: dimmed)
        .motionAnimation(Motion.standard(0.18), value: isSelected)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - 设置分类图标语义色（SettingsCategory 扩展）

extension SettingsCategory {
    /// 左侧导航图标的语义色（macOS System Settings 风格的彩色分类）。
    var iconColor: Color {
        switch self {
        case .general: return .gray
        case .recognition: return .blue
        case .translation: return .orange
        case .captions: return .purple
        case .audio: return .red
        case .history: return .teal
        case .appleServices: return .primary
        case .systemStatus: return .green
        }
    }

    /// 页首色块用色（appleServices 的 .primary 在黑底上不可见，用深灰）。
    var pageHeaderColor: Color {
        self == .appleServices ? Color(white: 0.35) : iconColor
    }
}

// MARK: - 行内标签（RowLabel）
//
// 参考图行样式：粗体标题 + 灰色说明第二行（说明属于行本身，
// 不再游离在整行下方）。控制项（Toggle/Picker/Slider）放右侧。

struct RowLabel: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
