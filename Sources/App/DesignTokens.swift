import AppKit
import SwiftUI

// MARK: - 设计令牌

/*
 本文件的每个数值都移植自 https://recent.design 的前端样式表
 （assets/app-Bdsol5fQ.css，2026-09-03 提取），只搬「规则」：
 圆角阶梯 / 半透明墨色 alpha / 缓动曲线 / 遮罩 ramp / 字号阶梯，
 不引第三方依赖、不使用其素材与字体文件。

 映射约定：
 • 站点用 oklch(0% 0 0 / α) 表达「半透明黑描边/底色」——它靠透明度
   自动适配深浅色。SwiftUI 里的等价物是 Color.primary.opacity(α)，
   在 dark mode 自动反相成半透明白，语义一致。
 • 站点字体 Inter / Departure Mono（自有素材）→ 本地用 SF Pro / SF Mono 顶替。
 • 站点按钮只有 ghost（透明）与 soft（tint 淡底）两个变体，全站无实心色块；
   本 App 的激活态一律走 soft，避免出现满宽饱和蓝选中块。
 */

/// 圆角阶梯（站点 border-radius 实测出现的 6 档 + 胶囊）。
enum Corner {
    /// 4px —— 最小控件（内联标记、勾选框）
    static let tiny: CGFloat = 4
    /// 8px —— 行、输入框
    static let small: CGFloat = 8
    /// 10px —— 卡片
    static let card: CGFloat = 10
    /// 12px —— 浮层卡片
    static let medium: CGFloat = 12
    /// 16px —— 大浮层 / 独立面板
    static let large: CGFloat = 16
    /// 18px —— 主视觉容器
    static let xl: CGFloat = 18
    /// 9999px —— 胶囊
    static let pill: CGFloat = 9999

    static func rect(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// 墨色阶梯：全部是「带透明度的 primary」，深浅色自适应。
/// 数字取自站点 CSS 里出现频率最高的几档 alpha。
enum Ink {
    /// .153 —— 默认描边（oklch(0% 0 0 / .153)）
    static let hairline = Color.primary.opacity(0.153)
    /// .267 —— 悬停/聚焦时的描边加粗
    static let ring = Color.primary.opacity(0.267)
    /// .122 —— soft 变体的激活底色
    static let active = Color.primary.opacity(0.122)
    /// .09 —— hover 底色（全站 hover 只加这一层，不动颜色）
    static let hover = Color.primary.opacity(0.09)
    /// .063 —— 次级底色（分段容器、轨道）
    static let subtle = Color.primary.opacity(0.063)
    /// .04 —— 最弱分隔（交替行、内嵌容器）
    static let faint = Color.primary.opacity(0.04)
    /// .486 —— 次级文字（站点 --x156kdii）
    static let secondary = Color.primary.opacity(0.486)
    /// .2 —— 分隔线（比 hairline 更轻）
    static let divider = Color.primary.opacity(0.2)
    /// 列表悬停聚焦：hover 某行时其余行压到 0.4（站点
    /// `.default-marker:hover > li:not(:hover) { opacity: .4 }`）。
    static let dimmedSibling: Double = 0.4

    /// tint 淡底（soft 变体 / 选中徽章）：accent 的低透明度层。
    static func soft(_ color: Color = Color.accentColor, _ alpha: Double = 0.12) -> Color {
        color.opacity(alpha)
    }
}

// MARK: - 动效

/// 系统「减少动态效果」开关的运行时镜像。
///
/// 站点把 `@media (prefers-reduced-motion: reduce)` 包在每一条动画上，
/// 降级方式是「瞬间归位」而不是删掉状态。这里用同一个语义：
/// 曲线在 reduce 时返回 nil，视图直接落到终态。
@MainActor
final class MotionPrefs {
    static let shared = MotionPrefs()
    var reduceMotion = false
    private init() {}
}

enum Motion {
    /// 出场/入场（cubic-bezier(.16, 1, .3, 1)）——先冲后缓，站点用于面板展开。
    static func exit(_ duration: Double = 0.32) -> Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: duration)
    }

    /// 标准态变化（cubic-bezier(.4, 0, .2, 1)）——hover/选中/展开。
    static func standard(_ duration: Double = 0.24) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: duration)
    }

    /// 快速反馈（cubic-bezier(.2, 0, 0, 1)）——按压、勾选。
    static func snap(_ duration: Double = 0.12) -> Animation {
        .timingCurve(0.2, 0, 0, 1, duration: duration)
    }

    /// 双向过渡（cubic-bezier(.65, 0, .35, 1)）——首尾都要加减速的位移。
    static func inOut(_ duration: Double = 0.3) -> Animation {
        .timingCurve(0.65, 0, 0.35, 1, duration: duration)
    }

    /// reduce-motion 闸门：真时返回 nil（瞬时归位）。
    @MainActor
    static func anim(_ animation: Animation?) -> Animation? {
        MotionPrefs.shared.reduceMotion ? nil : animation
    }

    /// 带闸门的 withAnimation。
    @MainActor
    static func run<T>(_ animation: Animation?, _ body: () -> T) {
        if MotionPrefs.shared.reduceMotion {
            _ = body()
        } else {
            _ = withAnimation(animation, body)
        }
    }
}

extension View {
    /// reduce-motion 安全的隐式动画。
    func motionAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionAnimationModifier(animation: animation, value: value))
    }
}

private struct MotionAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.animation(reduce ? nil : Motion.anim(animation), value: value)
    }
}

/// 挂在根视图上：把系统的 Reduce Motion 同步进 MotionPrefs，
/// 让 withAnimation 型调用点也能拿到同一个闸门。
struct ReduceMotionGate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .onAppear { MotionPrefs.shared.reduceMotion = reduce }
            .onChange(of: reduce) { _, newValue in
                MotionPrefs.shared.reduceMotion = newValue
            }
    }
}

extension View {
    func reduceMotionGate() -> some View { modifier(ReduceMotionGate()) }
}

// MARK: - 排版

/// 字号阶梯取自站点 font-size 实测集合（9/10/11/12/13/14/16/17/18/20/28/32/48），
/// 按 macOS 13pt 正文基准做了等比收敛。
enum Type {
    static let micro: CGFloat = 10      // 徽章/计数
    static let label: CGFloat = 11      // 等宽微标签
    static let caption: CGFloat = 12
    static let body: CGFloat = 13
    static let emphasis: CGFloat = 15
    static let title: CGFloat = 20
    static let display: CGFloat = 28

    /// 等宽只用于数字与微标签（站点 Departure Mono 的用法）。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// 标题负字距：站点 `-0.0175em`（大字号收紧，小字号不动）。
    static func titleTracking(_ size: CGFloat) -> CGFloat {
        size >= 15 ? -(size * 0.0175) : 0
    }

    /// 微标签正字距（等宽大写小字需要拆开才读得动）。
    static let labelTracking: CGFloat = 0.3
}

extension View {
    /// 给标题类文本套负字距。
    func titleTracking(_ size: CGFloat) -> some View {
        tracking(Type.titleTracking(size))
    }
}

// MARK: - 遮罩（边缘渐隐）

/// 站点底部渐隐遮罩的精确配方：
/// `linear-gradient(#0000 0, #00000014 8px, #00000059 22px, #000000bf 36px, #000 48px)`
/// 即 alpha 0 → .08 → .35 → .75 → 1，落在 0/8/22/36/48px 五个位置。
/// 比线性渐变更柔和：越靠近内容越透明，滚出去的文字是「淡没」而不是「切断」。
enum EdgeFade {
    static let length: CGFloat = 48

    /// 站点配方：距边缘 d 像素处的不透明度
    /// 0 → .08(8px) → .35(22px) → .75(36px) → 1(48px)。
    static func alpha(at distance: CGFloat) -> Double {
        switch distance {
        case ..<8: return 0.08 * (distance / 8)
        case ..<22: return 0.08 + 0.27 * ((distance - 8) / 14)
        case ..<36: return 0.35 + 0.40 * ((distance - 22) / 14)
        case ..<length: return 0.75 + 0.25 * ((distance - 36) / 12)
        default: return 1
        }
    }

    /// 以「像素」为单位的 stop 序列（horizontal 时左右对称）。
    static func stops(total: CGFloat, band: CGFloat) -> [Gradient.Stop] {
        guard band > 0, total > band * 2.2 else {
            // 视口太矮/太窄时不淡出，否则会看到整块内容被压暗。
            return [.init(color: .black, location: 0), .init(color: .black, location: 1)]
        }
        let sample = stride(from: CGFloat(0), through: band, by: 4).map { d in
            Gradient.Stop(color: .black.opacity(alpha(at: d)), location: d / total)
        }
        // 渐变 stops 必须按 location 升序：从 (total-band) 递增回 total。
        let mirrored = stride(from: total - band, through: total, by: 4).map { p in
            Gradient.Stop(color: .black.opacity(alpha(at: total - p)), location: p / total)
        }
        return sample + [.init(color: .black, location: 0.5)] + mirrored
    }
}

extension View {
    /// 上下两端渐隐（长滚动容器用）。
    func edgeFadeVertical(_ band: CGFloat = EdgeFade.length) -> some View {
        modifier(EdgeFadeModifier(band: band, horizontal: false))
    }

    /// 左右两端渐隐（横向胶囊轨道用，替代滚动条）。
    func edgeFadeHorizontal(_ band: CGFloat = 24) -> some View {
        modifier(EdgeFadeModifier(band: band, horizontal: true))
    }
}

private struct EdgeFadeModifier: ViewModifier {
    var band: CGFloat
    var horizontal: Bool

    func body(content: Content) -> some View {
        content.mask {
            // mask 的尺寸 = 被遮罩内容的视口尺寸，在这里直接量宽高，
            // 不需要 preference/onGeometryChange（也就没有滚动期重算）。
            GeometryReader { geo in
                let total = horizontal ? geo.size.width : geo.size.height
                LinearGradient(
                    stops: EdgeFade.stops(total: total, band: band),
                    startPoint: horizontal ? .leading : .top,
                    endPoint: horizontal ? .trailing : .bottom
                )
            }
        }
    }
}

// MARK: - 控件变体

/// ghost：透明底，hover 加一层 Ink.hover；用于工具条图标按钮。
struct GhostButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var corner: CGFloat = Corner.small
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .background(
                Corner.rect(corner)
                    .fill(hovering ? (configuration.isPressed ? Ink.active : Ink.hover) : .clear)
            )
            .onHover { hovering = $0 }
            .motionAnimation(Motion.snap(0.1), value: hovering)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.anim(Motion.snap(0.1)), value: configuration.isPressed)
    }
}

/// 胶囊 chip（站点 aria-pressed 的筛选/速度/主题选项一律用它）。
struct ChipStyle: ViewModifier {
    var selected: Bool = false
    var tint: Color = Color.accentColor
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(Type.mono(Type.label, weight: .medium))
            .foregroundStyle(selected ? tint : Ink.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(selected ? Ink.soft(tint, 0.14)
                                        : (hovering ? Ink.hover : Ink.faint))
            )
            .overlay(
                Capsule().strokeBorder(selected ? tint.opacity(0.35) : .clear, lineWidth: 0.5)
            )
            .onHover { hovering = $0 }
            .motionAnimation(Motion.standard(0.18), value: hovering)
            .motionAnimation(Motion.standard(0.18), value: selected)
    }
}

extension View {
    func chipStyle(selected: Bool = false, tint: Color = Color.accentColor) -> some View {
        modifier(ChipStyle(selected: selected, tint: tint))
    }
}

/// tint 徽章：同色淡底 + 同色文字（状态类信息用，饱和度压到 0.12~0.16）。
struct TintBadge: View {
    let text: String
    var color: Color = Color.accentColor

    var body: some View {
        Text(text)
            .font(Type.mono(Type.micro, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Corner.rect(Corner.tiny).fill(Ink.soft(color, 0.14)))
    }
}

/// 导航/列表激活点：站点用 `sidebar-active-dot`（一个小圆点）而不是底色块。
struct ActiveDot: View {
    var active: Bool
    var color: Color = Color.accentColor

    var body: some View {
        Circle()
            .fill(active ? color : .clear)
            .frame(width: 4, height: 4)
            .motionAnimation(Motion.standard(0.2), value: active)
    }
}

/// 发丝分隔线（1px 但视觉重量极低）。
struct HairlineDivider: View {
    var vertical: Bool = false

    var body: some View {
        if vertical {
            Rectangle().fill(Ink.divider).frame(width: 1)
                .accessibilityHidden(true)
        } else {
            Rectangle().fill(Ink.divider).frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 布局常量

enum Metrics {
    /// 历史栏固定宽度（自绘双栏；不用 NavigationSplitView 的可调栏，
    /// 换取行模板的列宽确定性）。
    static let railWidth: CGFloat = 268
    static let rowHeight: CGFloat = 44
    static let gutter: CGFloat = 20

    /// 间距阶梯（站点 gap 实测集合 2/4/6/8/10/12/16/20/24/32/40/48）。
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

/// 语义色：把状态映射到系统动力色（深浅色各自适配），
/// 并统一压到低饱和淡底用法上。
enum Palette {
    static let ok = Color.green
    static let warn = Color.orange
    static let danger = Color.red
    static let live = Color.red
    static let info = Color.accentColor
    /// 译文色沿用系统的 teal/blue 动态对（DetailView 原实现），集中在此。
    static let translation = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemTeal.withAlphaComponent(0.85)
            : NSColor.systemBlue.withAlphaComponent(0.75)
    })
}
