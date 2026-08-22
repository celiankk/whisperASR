import Foundation

// MARK: - 多语言分句规则（SentenceRules）— 移植 yasbd-lib 母语级规则
//
// 按 Unicode 脚本路由到各语言的句末标点规则（对标 LiveTranslate 用的
// yasbd-lib 17 语言原生分句；脚本级路由天然覆盖其语言清单的超集）：
//
// | 脚本/语言           | 句末标点                          | 备注 |
// |--------------------|----------------------------------|------|
// | 中文 / 日文         | 。？！                            | 原有 |
// | 韩文               | . ? !                            | 原有（西式） |
// | 拉丁（en/de/fr/es/it/pt/sv/da/fi…） | . ? !            | 小数/缩写保护 |
// | 西里尔（ru/bg/kk-西） | . ? !                          | 同上 |
// | 希腊文             | . ; ! ?                         | 「;」是希腊问号 |
// | 阿拉伯文（ar/fa/ur/ps） | . ؟ ! ۔                    | ۔ 乌尔都/哈萨克句号 |
// | 希伯来文           | . ? !                            | |
// | 天城文（hi/mr/ne）  | । ॥ ? !                         | danda / 双 danda |
// | 亚美尼亚文         | ։ ? !                            | ։ 是句号 |
// | 埃塞文（am 提格雷尼亚） | ። ፧ ? !                     | |
// | 泰文/老挝文/缅甸文  | （无句末标点）                    | 书写无句号 → VAD+长度兜底 |
//
// 流式语境的两项误判保护（yasbd 批量规则在流式的等价改造）：
// 1. 小数保护：「3.」结尾的句点不立即断句（前字符是数字且句点后无内容
//    = 流式未决；下一轮字符到达后自然判定：「3.14」→ 非终止）。
// 2. 缩写保护：句点前的词是常见缩写（Mr./Dr./e.g. 等）不判句末
//    （流式 ASR 转写少见，但字幕场景 worth 防御）。

/// 文本脚本分类（按 Unicode 区段扫描；混合文本取首个命中优先级）。
enum SentenceScript {
    case latin
    case cyrillic
    case greek
    case arabic          // 阿拉伯文系：ar / fa / ur / ps / kk（阿拉伯文哈萨克）
    case hebrew
    case devanagari      // 天城文系：hi / mr / ne
    case armenian
    case ethiopic        // 埃塞文系：am / ti
    case thaiLaoMyanmar  // 无句末标点系
    case cjk             // 中文 / 日文
    case korean
    case mixed           // 无法判定：保守全集

    /// 扫描文本判定脚本（优先级：低频脚本 → 高频脚本，避免拉丁数字污染判定）。
    static func detect(_ text: String) -> SentenceScript {
        var hasLatin = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x0530...0x058F: return .armenian
            case 0x0590...0x05FF: return .hebrew
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                return .arabic
            case 0x0900...0x097F: return .devanagari
            case 0x1200...0x137F: return .ethiopic
            case 0x0E00...0x0E7F, 0x0E80...0x0EFF, 0x1000...0x109F:
                return .thaiLaoMyanmar
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F:
                return .korean
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xFF66...0xFF9D:
                return .cjk
            case 0x0400...0x052F: return .cyrillic
            case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
                hasLatin = true
            default:
                continue
            }
        }
        return hasLatin ? .latin : .mixed
    }
}

/// 单语言的分句规则。
struct SentenceRules {
    /// 句末终止符（文本以这些字符结尾 = 一句结束）。
    let terminators: Set<Character>
    /// 句点是否需小数/缩写保护（拉丁/西里尔书面传统；CJK 句号无歧义）。
    let decimalGuardedPeriod: Bool

    /// 判定文本是否以句末终止符结束（含小数/缩写保护）。
    /// - Parameter text: 完整累积文本（流式当前快照）。
    func endsWithTerminator(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        guard terminators.contains(last) else { return false }
        guard decimalGuardedPeriod, last == "." else { return true }

        // —— 句点保护（拉丁/西里尔）——
        let before = text.dropLast()
        // 缩写保护：句点前最后一个"词"是常见缩写 → 非句末。
        if let word = Self.lastWordToken(before), Self.abbreviations.contains(word) {
            return false
        }
        // 小数保护：句点前一字符是数字且句点后无内容（流式未决）→ 不立即断；
        // 下一轮若为「3.14」则 last 变成数字（非终止符），「3. 」后接新词时
        // 由后续终止符/兜底收口。
        if let prev = before.last, prev.isNumber {
            return false
        }
        return true
    }

    /// 提取句点前的最后一个词元（小写；仅字母数字与点）。
    private static func lastWordToken(_ text: Substring) -> String? {
        var token = ""
        for ch in text.reversed() {
            if ch.isLetter || ch.isNumber || ch == "." {
                token.insert(ch, at: token.startIndex)
            } else {
                break
            }
        }
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// 常见缩写（流式 ASR 低频但防御性覆盖；yasbd 各语言缩写表的精简集）。
    static let abbreviations: Set<String> = [
        // 英文
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
        "e.g", "i.e", "fig", "approx", "dept", "inc", "ltd", "co", "no",
        "u.s", "u.k", "a.m", "p.m",
        // 德/法/西/意
        "z.b", "bzw", "usw", "nr", "ggf", "etc", "p.ex", "mme", "mlle",
        "sr", "sra", "srta", "av", "pag",
        // 俄
        "т", "е", "т.д", "др", "г", "ул", "им",
    ]

    /// 按脚本取规则。
    static func rules(for script: SentenceScript) -> SentenceRules {
        switch script {
        case .cjk:
            // 中英/日英混排极常见：西文句点纳入终止符（带小数/缩写保护，
            // 中文句号「。」无歧义不受保护影响）。
            return .init(terminators: ["。", "？", "！", ".", "?", "!"], decimalGuardedPeriod: true)
        case .korean, .latin, .cyrillic:
            return .init(terminators: [".", "?", "!"], decimalGuardedPeriod: true)
        case .greek:
            // 希腊语「;」(ano teleia 语义) 是问号；「·」是分隔号不终止。
            return .init(terminators: [".", ";", "?", "!"], decimalGuardedPeriod: true)
        case .arabic:
            // ？ar/fa/ur/ps：阿拉伯问号 ؟、乌尔都句号 ۔、西式句点并存。
            return .init(terminators: [".", "؟", "!", "۔", "?"], decimalGuardedPeriod: false)
        case .hebrew:
            return .init(terminators: [".", "?", "!"], decimalGuardedPeriod: true)
        case .devanagari:
            // danda । 与双 danda ॥；句点也常见（现代书写）。
            return .init(terminators: ["।", "॥", ".", "?", "!"], decimalGuardedPeriod: false)
        case .armenian:
            // ։ 是亚美尼亚句号。
            return .init(terminators: ["։", ".", "?", "!"], decimalGuardedPeriod: false)
        case .ethiopic:
            // ። 句号 / ፧ 问号。
            return .init(terminators: ["።", "፧", ".", "?", "!"], decimalGuardedPeriod: false)
        case .thaiLaoMyanmar:
            // 泰/老挝/缅甸书写无句末标点：空格分段。终止符为空集，
            // 分句完全依赖 VAD 停顿 + 长度兜底（母语实况如此）。
            return .init(terminators: [], decimalGuardedPeriod: false)
        case .mixed:
            // 保守全集（含 CJK 三符 + 西文三符）；句点带保护。
            return .init(terminators: ["。", "？", "！", ".", "?", "!"], decimalGuardedPeriod: true)
        }
    }

    /// 便捷入口：文本 → 其脚本规则。
    static func rules(for text: String) -> SentenceRules {
        rules(for: SentenceScript.detect(text))
    }
}
