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
    // 悬停聚焦：与历史 rail 同一手法（hover 行外兄弟压到 0.4）。
    @State private var hoveredCategory: SettingsCategory?

    var body: some View {
        HStack(spacing: 0) {
            navRail
                .frame(width: 176)

            HairlineDivider(vertical: true)

            VStack(alignment: .leading, spacing: Metrics.lg) {
                SettingsPageHeader(
                    title: selection.title,
                    icon: selection.icon,
                    color: selection.pageHeaderColor)
                detailView(for: selection)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.xl)
            .padding(.bottom, Metrics.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 660, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { settings.reload() }
    }

    /// 左栏导航：自绘行（露边圆角 + 激活点），不用系统 List 的满宽实心选中块。
    private var navRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置")
                .font(Type.mono(Type.label, weight: .medium))
                .tracking(Type.labelTracking)
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, Metrics.md)
                .padding(.bottom, Metrics.xs)

            ForEach(SettingsCategory.allCases) { category in
                SettingsNavRow(
                    category: category,
                    isSelected: selection == category,
                    dimmed: hoveredCategory != nil && hoveredCategory != category,
                    onSelect: { selection = category }
                )
                .onHover { inside in
                    hoveredCategory = inside ? category : (hoveredCategory == category ? nil : hoveredCategory)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Metrics.md)
        .padding(.vertical, Metrics.lg)
        .background(Ink.faint)
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
