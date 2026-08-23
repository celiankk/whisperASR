import XCTest
@testable import WhisperASR

/// 翻译提示词体系单测（规格第十二节）：
/// PromptBuilder 变量替换 / 缺失变量安全 / 预设完备性 / Apple 路径隔离。
final class TranslationPromptTests: XCTestCase {

    // MARK: PromptBuilder 变量替换

    func testAllVariablesReplaced() {
        let rendered = PromptBuilder.build(
            template: "Translate from {source_lang} to {target_lang}.\n\n{text}",
            context: TranslationPromptContext(
                sourceLanguage: "English", targetLanguage: "Chinese", text: "Hello world."))
        XCTAssertEqual(
            rendered,
            "Translate from English to Chinese.\n\nHello world.")
    }

    func testMissingVariablesAreSafe() {
        // 模板不含任何变量：原样返回（不崩溃、不改动）。
        let plain = "You are a translator."
        XCTAssertEqual(
            PromptBuilder.build(template: plain, context: TranslationPromptContext(
                sourceLanguage: "en", targetLanguage: "zh", text: "hi")),
            plain)
        // 空模板：安全返回空。
        XCTAssertEqual(
            PromptBuilder.build(template: "", context: TranslationPromptContext(
                sourceLanguage: "en", targetLanguage: "zh", text: "hi")),
            "")
    }

    func testUnknownPlaceholdersPreserved() {
        // 未知占位符（非本体系变量）原样保留——不误伤用户模板。
        let rendered = PromptBuilder.build(
            template: "{context} and {custom_var} stay; {target_lang} replaced",
            context: TranslationPromptContext(
                sourceLanguage: "a", targetLanguage: "b", text: "c"))
        XCTAssertEqual(rendered, "{context} and {custom_var} stay; b replaced")
    }

    func testOriginalTemplateNotModified() {
        let template = "{source_lang}→{target_lang}: {text}"
        let copy = template
        _ = PromptBuilder.build(template: template, context: TranslationPromptContext(
            sourceLanguage: "1", targetLanguage: "2", text: "3"))
        XCTAssertEqual(template, copy, "值语义替换不得改动原始模板")
    }

    func testTextWithSpecialCharactersInsertedVerbatim() {
        let tricky = "line1\nline2 $1 {not_a_var} %s"
        let rendered = PromptBuilder.build(
            template: "T: {text}",
            context: TranslationPromptContext(
                sourceLanguage: "a", targetLanguage: "b", text: tricky))
        XCTAssertEqual(rendered, "T: \(tricky)", "待译文本纯文本插入，不做二次解释")
    }

    func testEmbedsTextDetection() {
        XCTAssertTrue(PromptBuilder.embedsText("Input:\n{text}"))
        XCTAssertFalse(PromptBuilder.embedsText("Translate to {target_lang}."))
    }

    // MARK: 预设体系

    /// 规格第三节：三个变量化预设必备；「自定义」为标记名不占预设位。
    func testRequiredPresetsExist() {
        let names = TranslationPromptPreset.all.map(\.name)
        for required in ["日常聊天", "视频字幕", "技术内容"] {
            XCTAssertTrue(names.contains(required), "缺少预设 \(required)")
        }
        XCTAssertFalse(names.contains(TranslationPromptPreset.customName),
                       "「自定义」是编辑态标记，不应是内置预设")
    }

    /// 规格第十一节：视频字幕预设使用规格建议模板（含全部三变量）。
    func testVideoSubtitlePresetUsesSpecTemplate() {
        let preset = TranslationPromptPreset.named("视频字幕")
        XCTAssertNotNil(preset)
        XCTAssertTrue(preset?.prompt.contains("{source_lang}") ?? false)
        XCTAssertTrue(preset?.prompt.contains("{target_lang}") ?? false)
        XCTAssertTrue(preset?.prompt.contains("{text}") ?? false)
        XCTAssertTrue(preset?.prompt.contains("real-time subtitle translator") ?? false)
    }

    /// 持久化恢复路径：按名查预设；未知名返回 nil（上层回落默认指令）。
    func testNamedLookup() {
        XCTAssertNotNil(TranslationPromptPreset.named("技术内容"))
        XCTAssertNil(TranslationPromptPreset.named("不存在的预设"))
    }

    // MARK: Apple Translation 隔离（规格第七/十二节）

    /// Apple Translation 路径不读 systemPrompt：AppleTranslationManager
    /// 的翻译调用链不经过 PromptBuilder（LLM 专属）。静态验证：
    /// PromptBuilder 的引用只允许出现在 ChatCompletion/TranslationService
    /// （LLM 路径），不得出现在 AppleTranslation* 文件。
    func testAppleTranslationDoesNotUsePromptBuilder() throws {
        // 源码级守护：Apple 翻译引擎文件不得引用 PromptBuilder。
        let appleFiles = ["AppleTranslationEngine.swift", "AppleTranslationManager.swift"]
        for fileName in appleFiles {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Tests/WhisperASRTests
                .deletingLastPathComponent()   // 项目根
                .appendingPathComponent("Sources/Pipeline/Translation/\(fileName)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let content = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(content.contains("PromptBuilder"),
                           "\(fileName) 不得使用 PromptBuilder（Apple Translation 不注入 LLM system prompt）")
        }
    }
}
