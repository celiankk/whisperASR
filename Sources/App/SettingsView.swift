import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 设置分类

/// 左侧导航分类（macOS System Settings 风格）。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case recognition
    case translation
    case captions
    case audio
    case history
    case appleServices
    case systemStatus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .recognition: return "识别"
        case .translation: return "翻译"
        case .captions: return "字幕"
        case .audio: return "音频"
        case .history: return "记录"
        case .appleServices: return "Apple 服务"
        case .systemStatus: return "系统状态"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .recognition: return "waveform"
        case .translation: return "character.bubble"
        case .captions: return "captions.bubble"
        case .audio: return "mic"
        case .history: return "clock.arrow.circlepath"
        case .appleServices: return "apple.logo"
        case .systemStatus: return "chart.bar"
        }
    }
}

// MARK: - 设置容器

/// 设置中心：左侧分类导航 + 右侧内容区（参考 macOS System Settings）。
/// 主窗口内嵌（ContentView 切换）与 Settings 场景（⌘,）共用本视图。
/// 页面数据一律绑定 ConfigurationManager；切换分类只换右侧内容，不重置任何设置。
struct SettingsView: View {
    @State private var settings = ConfigurationManager.shared
    @State private var selection: SettingsCategory = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                HStack(spacing: 8) {
                    Image(systemName: category.icon)
                        .foregroundStyle(category.iconColor)
                        .frame(width: 18)
                    Text(category.title)
                }
                .tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 210)
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                SettingsPageHeader(
                    title: selection.title,
                    icon: selection.icon,
                    color: selection.pageHeaderColor)
                detailView(for: selection)
            }
            .padding(.top, 8)
        }
        .frame(minWidth: 660, minHeight: 460)
        .onAppear { settings.reload() }
    }

    @ViewBuilder
    private func detailView(for category: SettingsCategory) -> some View {
        switch category {
        case .general: GeneralSettingsView()
        case .recognition: RecognitionSettingsView()
        case .translation: TranslationSettingsView()
        case .captions: CaptionSettingsView()
        case .audio: AudioSettingsView()
        case .history: HistorySettingsView()
        case .appleServices: AppleServicesSettingsView()
        case .systemStatus: SystemStatusSettingsView()
        }
    }

    // MARK: - 颜色助手（字幕边框 ColorPicker 绑定）

    /// hex string → Color（ColorPicker 绑定）。
    static func color(fromHex hex: String) -> Color? {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Color → hex string（持久化）。
    static func hex(from color: Color) -> String {
        let nsColor = NSColor(color)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(
            format: "%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
