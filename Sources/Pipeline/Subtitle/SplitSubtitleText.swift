import AppKit
import SwiftUI

// MARK: - 逐字动画字幕（SwiftUI 原生 SplitText 效果）
//
// 参考 React Bits SplitText（chars 拆分 + 错峰入场）的观感，用原生 SwiftUI 实现：
// - 按字符拆分，新字符淡入 + 上移 + 缩放（power3.out 缓动）；
// - 公共前缀 diff：已显示的字保持静态，只有新增字符触发入场动画；
// - 实时流式追加时不会重建已有字符视图（按 offset 稳定复用），
//   避免“每个 token 更新都重放整个动画”的高频重建；
// - 自动换行 + 每行居中（复用 SubtitleFlowLayout）；
// - diff 状态放在 @State 引用盒中，不参与 Observation，长时间运行开销恒定；
// - 超出 maxAnimatedChars 时自动退化为普通 Text（超长字幕保护）。
//
// FloatingLetter 架构对应关系：
//   FloatingLetter
//   ├── SplitSubtitleText        （字幕文本拆分 + 公共前缀 diff）
//   ├── StaticLetterView         （已显示字符，静态渲染）
//   ├── AnimatedLetterView       （单字符入场动画）
//   └── SubtitleFlowLayout       （自动换行居中）

struct SplitSubtitleText: View {
    var text: String
    var fontSize: CGFloat = 26
    var fontWeight: Font.Weight = .semibold
    var foregroundStyle: Color = .white
    /// 每个新字符之间的错峰延迟（秒）。
    var staggerDelay: Double = 0.08
    /// 单字符动画时长（秒）。
    var duration: Double = 0.5
    /// 入场起始偏移（向上移入）。
    var fromOffsetY: CGFloat = 30
    /// 入场起始缩放。
    var fromScale: CGFloat = 0.9
    /// 超出该字符数时退化为普通 Text（防止超长字幕带来大量视图）。
    var maxAnimatedChars = 200
    /// 整体对齐（跟随字幕对齐设置；默认居中）。
    var alignment: Alignment = .center

    @State private var diff = SplitSubtitleDiff()

    private var chars: [String] {
        text.map(String.init)
    }

    var body: some View {
        let current = chars
        let commonPrefix = updatedPrefix(current: current)

        if current.count > maxAnimatedChars {
            // 超长保护：普通 Text，保留系统换行/截断行为。
            Text(text)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(foregroundStyle)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
        } else if commonPrefix == 0, !current.isEmpty {
            // 句子更替（与上一句无公共前缀）：整行作为单一单位快速淡入。
            // 逐字重播在整句替换场景是「全屏重打」——旧句瞬间消失、新句
            // 几十个字逐个浮现，读完时间远超更新节奏，正是刷新难受的主因；
            // 追加场景（同一句增长）仍走逐字入场（打字感保留）。
            Text(text)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(foregroundStyle)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: alignment)
                .transition(.opacity)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.22)) {}
                }
        } else {
            SubtitleFlowLayout(
                horizontalSpacing: 0,
                lineSpacing: 2,
                textAlignment: alignment == .leading ? .leading : .center
            ) {
                ForEach(Array(current.enumerated()), id: \.offset) { index, char in
                    if index < commonPrefix {
                        StaticLetterView(
                            char: char,
                            fontSize: fontSize,
                            fontWeight: fontWeight,
                            foregroundStyle: foregroundStyle
                        )
                    } else {
                        AnimatedLetterView(
                            char: char,
                            delay: Double(index - commonPrefix) * staggerDelay,
                            duration: duration,
                            fromOffsetY: fromOffsetY,
                            fromScale: fromScale,
                            fontSize: fontSize,
                            fontWeight: fontWeight,
                            foregroundStyle: foregroundStyle
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    /// 分类静态/动画前缀。仅当文本真正变化时重算；同文本的后续重渲染
    /// 保持上次分类，避免中断正在进行的入场动画。
    private func updatedPrefix(current: [String]) -> Int {
        if diff.lastText != text {
            diff.prefix = Self.commonPrefixCount(diff.chars, current)
            diff.lastText = text
            diff.chars = current
        }
        return diff.prefix
    }

    /// 连续相同的前缀数量：这些字符已经显示过，不需要重播动画。
    private static func commonPrefixCount(_ previous: [String], _ current: [String]) -> Int {
        var count = 0
        while count < previous.count, count < current.count, previous[count] == current[count] {
            count += 1
        }
        return count
    }
}

/// 非可观察的 diff 状态盒：保存在 @State 中，不参与 Observation，
/// 避免每次字幕更新触发额外重渲染。
private final class SplitSubtitleDiff {
    var lastText = ""
    var chars: [String] = []
    var prefix = 0
}

// MARK: - 已显示字符（静态）

private struct StaticLetterView: View {
    let char: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let foregroundStyle: Color

    var body: some View {
        let size = subtitleSegmentSize(segment: char, fontSize: fontSize, fontWeight: fontWeight)
        Text(char)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundStyle)
            .fixedSize()
            .frame(width: size.width, height: size.height, alignment: .center)
    }
}

// MARK: - 单字符入场动画

private struct AnimatedLetterView: View {
    let char: String
    let delay: Double
    let duration: Double
    let fromOffsetY: CGFloat
    let fromScale: CGFloat
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let foregroundStyle: Color

    @State private var appeared = false

    private var bodySize: CGSize {
        subtitleSegmentSize(segment: char, fontSize: fontSize, fontWeight: fontWeight)
    }

    /// power3.out 缓动曲线（与 React Bits ease="power3.out" 观感一致）。
    private var entranceAnimation: Animation {
        .timingCurve(0.215, 0.61, 0.355, 1.0, duration: duration)
    }

    var body: some View {
        Text(char)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundStyle)
            .fixedSize()
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : fromOffsetY)
            .scaleEffect(appeared ? 1 : fromScale)
            .frame(width: bodySize.width, height: bodySize.height, alignment: .center)
            .onAppear {
                guard delay > 0 else {
                    withAnimation(entranceAnimation) { appeared = true }
                    return
                }
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    withAnimation(entranceAnimation) { appeared = true }
                }
            }
    }
}
