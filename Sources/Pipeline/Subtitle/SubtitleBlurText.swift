import AppKit
import SwiftUI

// MARK: - Subtitle entrance animation
//
// SwiftUI port of the BlurText (motion/react) entrance used by v2s-style
// subtitles: every word (or character for CJK) starts blurred/offset and
// staggers in with a two-step keyframe (blur 10 → 5 → 0, opacity 0 → 0.5 → 1,
// y -50 → 5 → 0). Shared by the live overlay and the debug subtitle preview.

struct SubtitleBlurText: View {
    let text: String
    var fontSize: CGFloat = 26
    var fontWeight: Font.Weight = .semibold
    var foregroundStyle: Color = .white
    /// Per-segment stagger delay (ms) — BlurText's `delay`.
    var staggerDelay: Double = 0.12
    /// Per keyframe-step duration — BlurText's `stepDuration`.
    var stepDuration: Double = 0.25
    var direction: Direction = .top

    /// Diff state kept OUTSIDE the observation system on purpose: mutating it
    /// must not trigger a re-render, otherwise the freshly inserted animated
    /// segments would be swapped for static ones before the keyframes play.
    @State private var diff = SubtitleDiff()

    enum Direction {
        case top, bottom
    }

    /// Words when the text contains spaces, otherwise individual characters
    /// (Chinese/Japanese subtitles have no spaces).
    private var usesWords: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).contains(" ")
    }

    private var segments: [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if usesWords {
            return trimmed.split(separator: " ").map(String.init)
        }
        return trimmed.map(String.init)
    }

    /// Apple-spec spacing: gaps match the font's own metrics — words separated
    /// by the natural space width, CJK glyphs by 0 (glyph-to-glyph), and lines
    /// packed at the font's line height.
    private var spacingMetrics: (wordSpacing: CGFloat, lineHeight: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: nsFontWeight(fontWeight))
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = font.ascender - font.descender + font.leading
        return (
            wordSpacing: usesWords ? spaceWidth : 0,
            lineHeight: lineHeight
        )
    }

    var body: some View {
        let metrics = spacingMetrics
        let current = segments
        let commonPrefixCount = updatedPrefix(current: current)

        SubtitleFlowLayout(horizontalSpacing: metrics.wordSpacing, lineSpacing: 0) {
            ForEach(Array(current.enumerated()), id: \.offset) { index, segment in
                if index < commonPrefixCount {
                    StaticSegmentView(
                        segment: segment,
                        fontSize: fontSize,
                        fontWeight: fontWeight,
                        foregroundStyle: foregroundStyle
                    )
                } else {
                    BlurSegmentView(
                        segment: segment,
                        delay: Double(index - commonPrefixCount) * staggerDelay,
                        stepDuration: stepDuration,
                        direction: direction,
                        fontSize: fontSize,
                        fontWeight: fontWeight,
                        foregroundStyle: foregroundStyle
                    )
                }
            }
        }
    }

    /// Classify animated vs static once per text value; later re-renders with
    /// the same text keep the same classification so in-flight entrance
    /// animations are never cancelled.
    private func updatedPrefix(current: [String]) -> Int {
        if diff.lastText != text {
            diff.prefix = Self.commonPrefixCount(diff.segments, current)
            diff.lastText = text
            diff.segments = current
        }
        return diff.prefix
    }

    /// Number of leading segments that were already displayed and should stay
    /// static instead of replaying the entrance animation.
    private static func commonPrefixCount(_ previous: [String], _ current: [String]) -> Int {
        var count = 0
        while count < previous.count, count < current.count, previous[count] == current[count] {
            count += 1
        }
        return count
    }
}

/// Non-observable box holding the last text and its diff classification.
private final class SubtitleDiff {
    var lastText = ""
    var segments: [String] = []
    var prefix = 0
}

// MARK: - Static segment (already displayed, no entrance animation)

private struct StaticSegmentView: View {
    let segment: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let foregroundStyle: Color

    var body: some View {
        let size = subtitleSegmentSize(segment: segment, fontSize: fontSize, fontWeight: fontWeight)
        Text(segment)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundStyle)
            .fixedSize()
            .frame(width: size.width, height: size.height, alignment: .center)
    }
}

// MARK: - Per-segment blur entrance

private struct BlurSegmentView: View {
    let segment: String
    let delay: Double
    let stepDuration: Double
    let direction: SubtitleBlurText.Direction
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let foregroundStyle: Color

    @State private var animate = false

    private struct BlurState {
        var blur: CGFloat = 10
        var opacity: Double = 0
        var y: CGFloat = -50
    }

    var body: some View {
        KeyframeAnimator(
            initialValue: BlurState(y: direction == .top ? -50 : 50),
            trigger: animate
        ) { state in
            Text(segment)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(foregroundStyle)
                .fixedSize()
                .blur(radius: state.blur)
                .opacity(state.opacity)
                .offset(y: state.y)
        } keyframes: { _ in
            KeyframeTrack(\.blur) {
                CubicKeyframe(5, duration: stepDuration)
                CubicKeyframe(0, duration: stepDuration)
            }
            KeyframeTrack(\.opacity) {
                CubicKeyframe(0.5, duration: stepDuration)
                CubicKeyframe(1, duration: stepDuration)
            }
            KeyframeTrack(\.y) {
                CubicKeyframe(direction == .top ? 5 : -5, duration: stepDuration)
                CubicKeyframe(0, duration: stepDuration)
            }
        }
        .frame(
            width: subtitleSegmentSize(segment: segment, fontSize: fontSize, fontWeight: fontWeight).width,
            height: subtitleSegmentSize(segment: segment, fontSize: fontSize, fontWeight: fontWeight).height,
            alignment: .center
        )
        .onAppear {
            guard delay > 0 else {
                animate = true
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                animate = true
            }
        }
    }
}

/// Exact rendered size of a segment, measured with AppKit so the flow layout
/// always sees stable, finite dimensions (animated views can report unreliable
/// intrinsic sizes, which previously stacked every word/character vertically).
func subtitleSegmentSize(segment: String, fontSize: CGFloat, fontWeight: Font.Weight) -> CGSize {
    let font = NSFont.systemFont(ofSize: fontSize, weight: nsFontWeight(fontWeight))
    let size = (segment as NSString).size(withAttributes: [.font: font])
    let lineHeight = font.ascender - font.descender + font.leading
    return CGSize(width: ceil(size.width) + 1, height: ceil(lineHeight))
}

func nsFontWeight(_ weight: Font.Weight) -> NSFont.Weight {
    switch weight {
    case .ultraLight: return .ultraLight
    case .thin: return .thin
    case .light: return .light
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .heavy: return .heavy
    case .black: return .black
    default: return .regular
    }
}

// MARK: - Centered wrapping layout for subtitle words

struct SubtitleFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var lineSpacing: CGFloat = 6
    /// 每行水平对齐（默认居中，保持旧调用行为；左对齐时从 minX 起排）。
    var textAlignment: HorizontalAlignment = .center

    private struct Row {
        var items: [(subview: Subviews.Element, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let rows = computeRows(maxWidth: proposedWidth ?? .greatestFiniteMagnitude, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = proposedWidth ?? (rows.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let startX = textAlignment == .leading
                ? bounds.minX
                : bounds.midX - row.width / 2
            var cursor = startX
            for (subview, size) in row.items {
                subview.place(
                    at: CGPoint(x: cursor, y: y),
                    proposal: ProposedViewSize(size)
                )
                cursor += size.width + horizontalSpacing
            }
            y += row.height + lineSpacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + horizontalSpacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            if row.items.isEmpty {
                row.width = size.width
            } else {
                row.width += horizontalSpacing + size.width
            }
            row.items.append((subview, size))
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty {
            rows.append(row)
        }
        return rows
    }
}
