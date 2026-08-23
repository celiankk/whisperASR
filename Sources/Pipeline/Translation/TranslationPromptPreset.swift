import Foundation

// MARK: - 翻译提示词预设（TranslationPromptPreset）
//
// 内置提示词预设体系（Pipeline 层——设置页 UI 与翻译运行时共用，
// 不放在 UI 文件里）。模板支持 PromptBuilder 三变量：
// {source_lang} / {target_lang} / {text}；不含变量的模板保持现行
// 结构（模板作 system、待译文本走 user 消息）。
//
// 持久化（ConfigurationManager.translation 配置对象）：
// - translationPromptPreset：当前选中的预设名（"自定义" = 用户编辑态）；
// - translationPromptTemplate：当前模板全文（预设选择只写一次值，
//   之后用户可自由修改）。

/// 翻译提示词预设。
struct TranslationPromptPreset: Equatable {
    let name: String
    let prompt: String

    /// 「自定义」标记名（选中它表示完全用户编辑；不对应固定模板）。
    static let customName = "自定义"

    /// 内置预设（规格第三节：日常聊天 / 视频字幕 / 技术内容 / 自定义；
    /// 另保留旧版场景预设兼容既有用户配置）。
    static let all: [TranslationPromptPreset] = [
        .init(name: "日常聊天",
              prompt: "You are a real-time translator for live conversations and streams.\n\nTranslate the input from {source_lang} to {target_lang}.\n\nRules:\n- Output only the translation.\n- Use casual, natural spoken language.\n- Preserve the speaker's tone and intent.\n- Silently fix obvious speech-recognition errors using context.\n\nInput:\n{text}\n\nOutput only the translation."),
        .init(name: "视频字幕",
              prompt: """
              You are a real-time subtitle translator.

              Translate the input from {source_lang} to {target_lang}.

              Rules:
              - Output only the translation.
              - Do not add explanations, notes, or alternatives.
              - Preserve names, brands, and important technical terms.
              - Keep the translation natural and concise for subtitles.
              - Preserve the speaker's meaning, tone, and intent.
              - Do not summarize or omit information.
              - If the input is incomplete, translate the available meaning naturally.

              Input:
              {text}

              Output only the translation.
              """),
        .init(name: "技术内容",
              prompt: "You are a technical content translator.\n\nTranslate the input from {source_lang} to {target_lang}.\n\nRules:\n- Technical accuracy above all: do not paraphrase professional terms.\n- Keep API names, commands, code, product names, and proper nouns in the original language.\n- Translate around them only when the target language requires it.\n- Output only the translation; no explanations.\n\nInput:\n{text}\n\nOutput only the translation."),
        .init(name: "会议口语",
              prompt: "你是实时会议字幕翻译。用简洁自然的口语体翻译，保留说话人语气；专业术语首次出现时在括号内附原文。"),
        .init(name: "影视字幕",
              prompt: "你是影视字幕翻译。译文必须简短（不超过原文长度的 1.2 倍）以匹配字幕节奏；意译优先，人名地名用通行译名。"),
        .init(name: "技术文档",
              prompt: "你是技术文档翻译。术语精确（保留 API 名/命令/代码原文不译），语态正式，逻辑关系词严谨。"),
        .init(name: "身份核验",
              prompt: "You are translating for identity verification. Preserve all names, dates, ID numbers, and document field values EXACTLY as written. Never transliterate or reformat identifiers."),
    ]

    /// 按名查预设（持久化恢复用；未命中返回 nil → 上层回落默认指令）。
    static func named(_ name: String) -> TranslationPromptPreset? {
        all.first { $0.name == name }
    }
}
