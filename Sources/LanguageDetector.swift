import Foundation

// MARK: - 语言检测模块（LanguageDetector）
//
// 自动检测 ASR 输出语言：中文（zh-CN/zh-TW/zh-HK）、英文、日文、韩文、
// 俄文、法文、德文；默认不固定中文（language = auto）。
// 仅用于状态显示与调试；所有语言统一进入 TranslationEngine（不做跳过）。

enum DetectedLanguage: String {
    case zhCN = "zh-CN"
    case zhTW = "zh-TW"
    case zhHK = "zh-HK"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case ru = "ru"
    case fr = "fr"
    case de = "de"
    case other = "other"

    var isChinese: Bool {
        switch self {
        case .zhCN, .zhTW, .zhHK: return true
        default: return false
        }
    }
}

enum LanguageDetector {
    /// 简体标记字。
    private static let simplifiedMarkers = Set<Character>("们吗里为这个说时候后来对没从还让学问题发现进过开关点觉务处于国区体现识议车间长来")
    /// 繁体标记字。
    private static let traditionalMarkers = Set<Character>("們嗎裡為這個說時後來對沒從還讓學問題發現進過開關點覺務處於國區體見識議車間長來")
    /// 粤语（zh-HK）标记字。
    private static let hkMarkers = Set<Character>("嘅咗嚟喺唔係乜嘢啲")
    /// 法文特有字符/词。
    private static let frenchMarkers = Set<Character>("éèêëàâçùûîïôœ")
    /// 德文特有字符/词。
    private static let germanMarkers = Set<Character>("äöüß")
    /// 德文高频词（无变音符号时用于区分英/德）。
    private static let germanWords: Set<String> = [
        "der", "die", "das", "und", "ist", "nicht", "ich", "sie", "wir",
        "guten", "morgen", "wie", "geht", "ihnen", "mit", "für", "auf",
        "ein", "eine", "zu", "sind", "haben", "wird", "auch", "bei", "von",
    ]
    /// 法文高频词（无特殊字符时用于区分英/法）。
    private static let frenchWords: Set<String> = [
        "le", "la", "les", "est", "bonjour", "comment", "vous", "pour",
        "avec", "une", "des", "je", "tu", "il", "elle", "nous", "ils",
        "dans", "sur", "pas", "mais", "être", "avoir", "qui", "que",
    ]

    /// 自动检测单段文本语言（按字符区间 + 语种标记）。
    static func detect(_ text: String) -> DetectedLanguage {
        let scalars = text.unicodeScalars
        var han = 0, kana = 0, hangul = 0, cyrillic = 0, latin = 0
        var french = 0, german = 0
        for scalar in scalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                han += 1
            } else if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) {
                kana += 1
            } else if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) {
                hangul += 1
            } else if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
                cyrillic += 1
            } else if (0x0041...0x007A).contains(v) {
                latin += 1
            }
            let ch = Character(String(scalar))
            if frenchMarkers.contains(ch) { french += 1 }
            if germanMarkers.contains(ch) { german += 1 }
        }

        if kana > 0 { return .ja }
        if hangul > 0 { return .ko }
        if cyrillic > 0 { return .ru }
        if han > 0 { return chineseVariant(text) }
        let words = Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty }
        )
        if !words.isDisjoint(with: germanWords) { return .de }
        if !words.isDisjoint(with: frenchWords) { return .fr }
        if german > 0 { return .de }
        if french > 0 { return .fr }
        if latin > 0 { return .en }
        return .other
    }

    private static func chineseVariant(_ text: String) -> DetectedLanguage {
        let chars = Set(text)
        if chars.intersection(hkMarkers).count > 0 { return .zhHK }
        let traditionalCount = chars.intersection(traditionalMarkers).count
        let simplifiedCount = chars.intersection(simplifiedMarkers).count
        return traditionalCount > simplifiedCount ? .zhTW : .zhCN
    }
}
