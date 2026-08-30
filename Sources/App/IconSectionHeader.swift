import SwiftUI

// MARK: - 设置页 Section 图标标题（IconSectionHeader）
//
// 统一的 Section header 组件：语义化 SF Symbol + 标题，替代纯文字
// header——长表单（识别/字幕页 6-8 个区块）加视觉锚点，扫读更快。
//
// 用法：Section("xxx") → Section(header: IconSectionHeader("xxx", icon: "yyy"))
// 图标配色按语义手选（与 macOS System Settings 的彩色分类图标一致风格）。

struct IconSectionHeader: View {
    let title: String
    let icon: String
    /// 图标着色（nil = secondary 单色；语义色提升扫读锚点）。
    var iconColor: Color? = nil

    init(_ title: String, icon: String, color: Color? = nil) {
        self.title = title
        self.icon = icon
        self.iconColor = color
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(iconColor ?? Color.secondary)
                .frame(width: 16)
            Text(title)
        }
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
}
