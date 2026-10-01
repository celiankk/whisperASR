import Foundation
import CoreText
import CoreGraphics
import AppKit

// MARK: - 字幕排版引擎（CoreText，文本/词边界变化时一次性执行）
//
// 职责：文本 + 词级时间戳 → [SubtitleGlyph]（quad + SDF 图集 UV + 词索引）。
// 排版结果与进度无关——60~120fps 的进度刷新只更新 Uniform（见
// MetalSubtitleRenderer），本引擎不被逐帧调用，布局重排由此杜绝。
//
// 词索引映射：CFStringTokenizer 语言学分词（拉丁按空格、中文按词）→
// UTF-16 字符下标 → 词索引表 → CTRunGetStringIndices 逐 glyph 归属。
// 规则：词间空白归前一个词（空白高亮在前词完成时结束，符合卡拉 OK 观感）。

/// 词级时间戳（CTC / 流式对齐产出）。
struct WordTimestamp: Equatable {
    let word: String
    let start: Double   // 秒
    let end: Double
}

/// 排版结果。
struct SubtitleLayoutResult {
    var glyphs: [SubtitleGlyph]
    /// 文本块总高（点，y 向下）。
    var textHeight: CGFloat
    /// 行数。
    var lineCount: Int
}

final class SubtitleGlyphLayoutEngine {

    let font: NSFont

    init(font: NSFont) {
        self.font = font
    }

    /// 排版：多行折行（宽度约束）+ 逐 glyph 词归属 + SDF 图集 UV。
    /// - Parameters:
    ///   - text: 字幕文本。
    ///   - width: 容器宽度（点）。
    ///   - atlas: SDF 图集（须以同字体生成；缺字形字符跳过该 glyph）。
    ///   - wordTimestamps: 词级时间戳（顺序与文本词序一致）。
    func layout(text: String,
                width: CGFloat,
                atlas: SDFGlyphAtlas,
                wordTimestamps: [WordTimestamp]) -> SubtitleLayoutResult {
        let nsText = text as NSString
        let totalUTF16 = nsText.length

        // 1. 分词：语言学分词 → 字符 → 词索引表。
        let charToWord = Self.buildCharToWordMap(text: text, wordTimestamps: wordTimestamps)

        // 2. 逐行折行，收集 (行内 CT 信息, 行基线 y-down)。
        guard totalUTF16 > 0 else {
            return SubtitleLayoutResult(glyphs: [], textHeight: 0, lineCount: 0)
        }

        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)

        struct LineInfo {
            let line: CTLine
            let baselineFromTop: CGFloat   // 基线（y 向下，相对文本块顶）
        }
        var lines: [LineInfo] = []
        var start = 0
        var yCursor: CGFloat = 0
        let lineStep = font.ascender - font.descender + font.leading
        while start < totalUTF16 {
            let breakLen = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            let len = max(1, breakLen)
            let range = CFRange(location: start, length: min(len, totalUTF16 - start))
            let line = CTTypesetterCreateLine(typesetter, range)
            lines.append(LineInfo(line: line, baselineFromTop: yCursor + font.ascender))
            yCursor += lineStep
            start += range.length
        }
        let textHeight = yCursor

        // 3. 逐 run 展开 glyph → quad + 词索引 + 图集 UV。
        var glyphs: [SubtitleGlyph] = []
        for lineInfo in lines {
            let runs = CTLineGetGlyphRuns(lineInfo.line) as! [CTRun]
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphIDs = [CGGlyph](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphIDs)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(), &positions)
                var stringIndices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(), &stringIndices)
                var boundingRects = [CGRect](repeating: .zero, count: count)
                // run 字体可能被 CoreText 替换为后备字体（CJK 等）——
                // 字形 bbox 必须按 run 实际字体度量。
                let runAttrs = CTRunGetAttributes(run) as NSDictionary
                let runCTFont: CTFont
                if let nsFont = runAttrs[kCTFontAttributeName] as? NSFont {
                    runCTFont = nsFont as CTFont   // NSFont ↔ CTFont toll-free
                } else {
                    runCTFont = font
                }
                CTFontGetBoundingRectsForGlyphs(runCTFont, .horizontal, &glyphIDs,
                                                &boundingRects, count)

                for i in 0..<count {
                    let bbox = boundingRects[i]
                    guard bbox.width > 0.25, bbox.height > 0.25 else { continue }   // 空白
                    let charIndex = stringIndices[i]
                    guard charIndex < totalUTF16 else { continue }
                    let key = Self.key(at: charIndex, in: nsText)
                    guard let entry = atlas.entries[key] else { continue }

                    // CT 行内坐标（基线 y 向上）→ 文本块 y 向下。
                    let x = positions[i].x + bbox.minX
                    let yTop = lineInfo.baselineFromTop - bbox.maxY
                    glyphs.append(SubtitleGlyph(
                        rect: CGRect(x: x, y: yTop, width: bbox.width, height: bbox.height),
                        uvRect: entry.uvRect,
                        wordIndex: charToWord[min(charIndex, charToWord.count - 1)]))
                }
            }
        }
        return SubtitleLayoutResult(glyphs: glyphs,
                                    textHeight: textHeight,
                                    lineCount: lines.count)
    }

    // MARK: 分词（UTF-16 词归属表）

    /// 语言学分词 → charToWord[utf16Index] = wordIndex。
    /// 词间空白归前一个词；未覆盖字符归 0。
    static func buildCharToWordMap(text: String,
                                   wordTimestamps: [WordTimestamp]) -> [Int] {
        let nsText = text as NSString
        let total = nsText.length
        var map = [Int](repeating: 0, count: total)
        guard !wordTimestamps.isEmpty, total > 0 else { return map }

        // 分词范围（不含空白），与 wordTimestamps 下标对齐（截断/溢出安全）。
        // locale = nil → 用户当前 locale（字幕场景与系统语言一致，中文分词有效）。
        let locale: CFLocale? = nil
        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault,
                                                text as CFString,
                                                CFRange(location: 0, length: total),
                                                kCFStringTokenizerUnitWord,
                                                locale)
        var wordRanges: [Range<Int>] = []
        var tokenType = CFStringTokenizerGoToTokenAtIndex(tokenizer, 0)
        while tokenType != [], wordRanges.count < wordTimestamps.count {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            wordRanges.append(range.location..<(range.location + range.length))
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        // 填表：词内 → 词序号；词间空白 → 前一词。
        var current = 0
        for index in 0..<total {
            while current < wordRanges.count, index >= wordRanges[current].upperBound {
                current += 1
            }
            if current < wordRanges.count, index >= wordRanges[current].lowerBound {
                map[index] = current
            } else {
                map[index] = max(0, current - 1)   // 词间空白归前一词
            }
        }
        return map
    }

    /// UTF-16 下标 → 图集 key（代理对聚合为单字符）。
    static func key(at utf16Index: Int, in nsText: NSString) -> String {
        let first = nsText.character(at: utf16Index)
        if UTF16.isLeadSurrogate(first), utf16Index + 1 < nsText.length {
            let second = nsText.character(at: utf16Index + 1)
            return String(decoding: [first, second], as: UTF16.self)
        }
        return String(decoding: [first], as: UTF16.self)
    }

    // MARK: 外部时钟 → 词级进度（与渲染解耦的桥）

    /// 时间 → 词级浮点进度（3.4 = 第 4 词过渡 40%）。
    /// 规则：词 i 在 [start_i, end_i] 内线性过渡；词间隙维持前词完成态。
    static func progress(at time: Double, words: [WordTimestamp]) -> Float {
        guard let first = words.first else { return 0 }
        if time <= first.start { return 0 }
        for (i, word) in words.enumerated() {
            if time < word.start {
                return Float(i)                       // 词间空隙：前词完成态
            }
            if time <= word.end {
                let span = max(word.end - word.start, 1e-6)
                let fraction = max(0, min(1, (time - word.start) / span))
                return Float(i) + Float(fraction)
            }
        }
        return Float(words.count)
    }
}
