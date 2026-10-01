import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Network

// MARK: - 字幕

struct CaptionSettingsView: View {
    @State private var settings = ConfigurationManager.shared

    /// 字幕主题预设：一键应用字号/背景透明度/边框/字重组合，
    /// 应用后仍可手动微调（预设只写一次配置，不锁定）。
    private struct SubtitleTheme {
        let name: String
        let icon: String
        let sourceFontSize: Double
        let backgroundOpacity: Double
        let borderVisible: Bool
        let borderOpacity: Double
        let fontWeight: String
        /// 默认主题（值 = AppState 出厂缺省；与手调默认区分开便于恢复）。
        var isDefault = false
    }

    private let themes: [SubtitleTheme] = [
        .init(name: "默认", icon: "arrow.counterclockwise",
              sourceFontSize: 32, backgroundOpacity: 0.4,
              borderVisible: true, borderOpacity: 0.6, fontWeight: "medium",
              isDefault: true),
        .init(name: "观影", icon: "film",
              sourceFontSize: 30, backgroundOpacity: 0.55,
              borderVisible: false, borderOpacity: 0, fontWeight: "medium"),
        .init(name: "会议", icon: "person.2",
              sourceFontSize: 24, backgroundOpacity: 0.34,
              borderVisible: true, borderOpacity: 0.8, fontWeight: "semibold"),
        .init(name: "极简", icon: "textformat",
              sourceFontSize: 28, backgroundOpacity: 0.15,
              borderVisible: false, borderOpacity: 0, fontWeight: "medium"),
        .init(name: "大字", icon: "textformat.size.larger",
              sourceFontSize: 44, backgroundOpacity: 0.45,
              borderVisible: false, borderOpacity: 0, fontWeight: "bold"),
        .init(name: "高对比", icon: "circle.lefthalf.filled",
              sourceFontSize: 32, backgroundOpacity: 0.78,
              borderVisible: false, borderOpacity: 0, fontWeight: "bold"),
    ]

    /// 当前样式是否与某预设完全匹配；不匹配任何预设 = 自定义
    ///（手动微调任一项后自动落入此态）。
    private func matchedThemeIndex(subtitle: SubtitleConfiguration) -> Int? {
        let borderOpacity = subtitle.editBorderVisible ? subtitle.editBorderOpacity : 0
        return themes.firstIndex { theme in
            theme.sourceFontSize == subtitle.sourceFontSize
                && theme.backgroundOpacity == subtitle.backgroundOpacity
                && theme.borderOpacity == borderOpacity
                && theme.fontWeight == subtitle.fontWeight
        }
    }

    var body: some View {
        @Bindable var caption = settings.subtitle
        @Bindable var window = settings.window

        Form {
            Section(header: IconSectionHeader("主题预设", icon: "paintpalette", color: .purple)) {
                // 横向轨道 + 两端渐隐（替代滚动条）：预设多时不挤压表单宽度。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.md) {
                        ForEach(Array(themes.enumerated()), id: \.offset) { index, theme in
                            PresetTile(
                                icon: theme.icon,
                                name: theme.name,
                                selected: matchedThemeIndex(subtitle: caption) == index,
                                help: "\(theme.name)：字号\(Int(theme.sourceFontSize)) / 背景\(Int(theme.backgroundOpacity * 100))%"
                            ) {
                                applyTheme(theme)
                            }
                        }
                        // 自定义徽标：非预设组合时显示（手动微调自动落入）。
                        if matchedThemeIndex(subtitle: caption) == nil {
                            PresetTile(
                                icon: "slider.horizontal.3",
                                name: "自定义",
                                selected: true,
                                help: "当前为手动微调的样式组合",
                                action: {}
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .edgeFadeHorizontal(20)
                Text("一键应用样式组合，应用后可继续手动微调下方各项；微调后标记为自定义。")
                    .font(Type.text(Type.caption))
                    .foregroundStyle(Ink.secondary)
            }

            Section(header: IconSectionHeader("字幕文字", icon: "textformat.size", color: .purple)) {
                HStack {
                    Text("原文字号")
                    Spacer()
                    Slider(value: $caption.sourceFontSize, in: 20...72)
                        .frame(width: 180)
                    Text("\(Int(caption.sourceFontSize))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                HStack {
                    Text("翻译字号")
                    Spacer()
                    Slider(value: $caption.translationFontSize, in: 20...72)
                        .frame(width: 180)
                    Text("\(Int(caption.translationFontSize))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                Picker("字体粗细", selection: $caption.fontWeight) {
                    Text("常规").tag("regular")
                    Text("中等").tag("medium")
                    Text("粗体").tag("bold")
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("行间距")
                    Spacer()
                    Slider(value: $caption.lineSpacing, in: 0...12)
                        .frame(width: 180)
                    Text("\(Int(caption.lineSpacing))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                Picker("文字对齐", selection: $caption.horizontalAlignment) {
                    Text("左对齐").tag("left")
                    Text("居中").tag("center")
                }
                .pickerStyle(.segmented)
                Picker("字幕最大行数", selection: $caption.maxLines) {
                    Text("1 行").tag(1)
                    Text("2 行").tag(2)
                    Text("3 行").tag(3)
                }
                Text("字号只影响字幕文字，不影响字幕框与窗口大小。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("字幕区域", icon: "rectangle.inset.filled", color: .purple)) {
                HStack {
                    Text("字幕宽度")
                    Spacer()
                    Slider(value: $caption.containerWidth, in: 400...1200)
                        .frame(width: 180)
                    Text("\(Int(caption.containerWidth))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("字幕高度")
                    Spacer()
                    Slider(value: $caption.containerHeight, in: 100...400)
                        .frame(width: 180)
                    Text("\(Int(caption.containerHeight))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Slider(value: $caption.backgroundOpacity, in: 0.1...0.8)
                        .frame(width: 180)
                    Text("\(Int(caption.backgroundOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("边框透明度")
                    Spacer()
                    Slider(value: $caption.borderOpacity, in: 0...0.3)
                        .frame(width: 180)
                    Text("\(Int(caption.borderOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Text("字幕框填满浮窗内容区：拖空白处移动窗口，拖边缘缩放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("字幕编辑边框", icon: "rectangle.dashed", color: .purple)) {
                Toggle("显示编辑边框", isOn: $caption.editBorderVisible)
                HStack {
                    Text("边框颜色")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: {
                            SettingsView.color(fromHex: caption.editBorderColorHex) ?? .white
                        },
                        set: { color in
                            caption.editBorderColorHex = SettingsView.hex(from: color)
                        }
                    ))
                    .labelsHidden()
                }
                HStack {
                    Text("边框透明度")
                    Spacer()
                    Slider(value: $caption.editBorderOpacity, in: 0...1)
                        .frame(width: 180)
                    Text("\(Int(caption.editBorderOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Text("只影响边框显示；关闭后窗口仍可移动与缩放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: IconSectionHeader("字幕浮层行为", icon: "cursorarrow.click.2", color: .purple)) {
                HStack {
                    Text("字幕空闲清除")
                    Spacer()
                    TextField("3", value: $caption.clearDelay, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                    Text("秒")
                        .foregroundStyle(.secondary)
                }
                Text("3 秒没有新的识别输入时自动清空浮窗字幕（1–10 秒）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("5 秒未点击自动隐藏控件", isOn: $window.autoHideControls)
                Button("浮层回到默认位置") {
                    settings.subtitle.resetOverlayPosition()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 应用主题预设（写入配置，不锁定——应用后仍可微调）。
    private func applyTheme(_ theme: SubtitleTheme) {
        let subtitle = settings.subtitle
        subtitle.sourceFontSize = theme.sourceFontSize
        subtitle.backgroundOpacity = theme.backgroundOpacity
        subtitle.editBorderVisible = theme.borderVisible
        subtitle.editBorderOpacity = theme.borderOpacity
        subtitle.fontWeight = theme.fontWeight
    }
}

// MARK: - 预设卡片（soft 变体）

/// 主题预设瓷片：未选 = Ink.faint + 发丝环；选中 = tint 14% 淡底 + accent 发丝环。
/// hover 只加一层淡底，不动颜色（站点的 ghost/soft 家族）。
private struct PresetTile: View {
    let icon: String
    let name: String
    let selected: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selected ? Color.accentColor : Ink.secondary)
                Text(name)
                    .font(Type.mono(Type.micro, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Ink.secondary)
            }
            .frame(width: 60, height: 46)
            .background(
                Corner.rect(Corner.card)
                    .fill(selected ? Ink.soft(Color.accentColor, 0.14)
                                   : (hovering ? Ink.hover : Ink.faint))
            )
            .overlay(
                Corner.rect(Corner.card).strokeBorder(
                    selected ? Color.accentColor.opacity(0.5) : Ink.hairline,
                    lineWidth: 0.5
                )
            )
            .contentShape(Corner.rect(Corner.card))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.anim(Motion.standard(0.18)), value: hovering)
        .animation(Motion.anim(Motion.standard(0.18)), value: selected)
        .help(help)
    }
}
