import Foundation

// MARK: - 翻译提示词构建器（PromptBuilder）
//
// 统一 Prompt 构建层：变量替换的唯一收口（规格禁止在各
// TranslationProvider 内重复实现）。模板来自设置页预设/自定义，
// 变量在请求发送前统一执行替换。
//
// 数据流：
//
//   ConfigurationManager（模板）→ PromptBuilder.build(template, context)
//       → TranslationService systemContent → LLM Provider
//
// Apple Translation 不经过本层（TranslationSession 无 system prompt
// 概念，行为不变）。

/// 单次翻译的提示词上下文。
struct TranslationPromptContext {
    let sourceLanguage: String
    let targetLanguage: String
    let text: String
}

enum PromptBuilder {
    /// 模板变量（编辑器帮助文案与此处一致）。
    enum Variable {
        static let sourceLang = "{source_lang}"
        static let targetLang = "{target_lang}"
        static let text = "{text}"
    }

    /// 执行变量替换：
    /// - 全部变量缺失安全（未出现的变量不处理、未知占位符原样保留）；
    /// - 不修改原始模板（值语义替换，返回新字符串）；
    /// - 替换值中的特殊字符不做二次解释（纯文本插入，无转义歧义）。
    static func build(template: String, context: TranslationPromptContext) -> String {
        guard !template.isEmpty else { return template }
        return template
            .replacingOccurrences(of: Variable.sourceLang, with: context.sourceLanguage)
            .replacingOccurrences(of: Variable.targetLang, with: context.targetLanguage)
            .replacingOccurrences(of: Variable.text, with: context.text)
    }

    /// 模板是否使用了 {text} 变量（决定待译文本的放置方式：
    /// 使用变量 = 文本已嵌入模板，user 消息只发原文编号；
    /// 未使用 = 保持现行结构，模板作 system、文本走 user 消息）。
    static func embedsText(_ template: String) -> Bool {
        template.contains(Variable.text)
    }
}
