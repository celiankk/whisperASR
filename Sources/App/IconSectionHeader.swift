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
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - 设置页页首（SettingsPageHeader）
//
// 参考图顶部样式：彩色圆角图标块（白 icon）+ 大号粗体标题。

struct SettingsPageHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(color))
            Text(title)
                .font(.system(size: 26, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
