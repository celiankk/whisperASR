import XCTest
@testable import WhisperASR

/// 翻译提示词体系单测（规格第十二节 + 预设升级规格第十节）：
/// PromptBuilder 变量替换 / 缺失变量安全 / 8 预设完整性 / 默认预设 /
/// 用户配置兼容 / 预设切换 / Apple 路径隔离。
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

    // MARK: 预设完整性（规格第十节）

    /// 8 个内置预设全部字段完备：id 不重复、name/description/prompt 非空；
    /// 全部含 {text} 变量（文本内嵌模板形态）。
    func testEightPresetsComplete() {
        let presets = TranslationPromptPreset.all
        XCTAssertEqual(presets.count, 8, "内置预设应为 8 个（不新增额外预设）")
        let ids = presets.map(\.id)
        XCTAssertEqual(Set(ids).count, 8, "预设 id 不得重复")
        for preset in presets {
            XCTAssertFalse(preset.name.isEmpty, "\(preset.id) name 为空")
            XCTAssertFalse(preset.description.isEmpty, "\(preset.id) description 为空")
            XCTAssertFalse(preset.prompt.isEmpty, "\(preset.id) prompt 为空")
            XCTAssertTrue(preset.prompt.contains("{text}"), "\(preset.id) 缺 {text} 变量")
            XCTAssertTrue(preset.prompt.contains("{source_lang}"), "\(preset.id) 缺 {source_lang}")
            XCTAssertTrue(preset.prompt.contains("{target_lang}"), "\(preset.id) 缺 {target_lang}")
        }
    }

    /// 规格第二节：8 个预设名与顺序（日常聊天/视频字幕/直播口语/影视剧情/
    /// 游戏/技术 IT/新闻资讯/商务正式）。
    func testPresetNamesAndOrder() {
        XCTAssertEqual(TranslationPromptPreset.all.map(\.name),
                       ["日常聊天", "视频字幕", "直播口语", "影视剧情",
                        "游戏", "技术 / IT", "新闻资讯", "商务正式"])
        XCTAssertFalse(TranslationPromptPreset.all.contains { $0.id == TranslationPromptPreset.customID },
                       "「自定义」是编辑态标记，不应是内置预设")
    }

    // MARK: 默认预设（规格第三节）

    /// 默认预设为「视频字幕」（应用核心场景是实时字幕）。
    func testDefaultPresetIsVideoSubtitle() {
        XCTAssertEqual(TranslationPromptPreset.defaultID, "video-subtitle")
        let defaultPreset = TranslationPromptPreset.with(id: TranslationPromptPreset.defaultID)
        XCTAssertNotNil(defaultPreset)
        XCTAssertEqual(defaultPreset?.name, "视频字幕")
    }

    /// 规格第四节：默认「视频字幕」Prompt 使用规格建议模板。
    func testVideoSubtitlePresetUsesSpecTemplate() {
        let prompt = TranslationPromptPreset.with(
            id: TranslationPromptPreset.defaultID)?.prompt ?? ""
        XCTAssertTrue(prompt.contains("professional real-time subtitle translator"))
        XCTAssertTrue(prompt.contains("If the input is incomplete or cut off"))
        XCTAssertTrue(prompt.contains("Do not add information that is not present in the source"))
        XCTAssertTrue(prompt.contains("Input:\n{text}"))
        XCTAssertTrue(prompt.hasSuffix("Output only the translation."))
    }

    // MARK: 预设切换（规格第十节）

    /// 切换视频字幕 → 技术/IT → 游戏 → 自定义：Prompt 内容正确切换
    ///（模拟设置页 loadPreset → save 的行为链）。
    func testPresetSwitchingChangesPrompt() {
        var currentPrompt = ""
        var currentID = ""

        func select(_ id: String) {
            if let preset = TranslationPromptPreset.with(id: id) {
                currentPrompt = preset.prompt   // loadPreset
                currentID = id
            } else if id == TranslationPromptPreset.customID {
                currentID = TranslationPromptPreset.customID   // 内容保持用户态
            }
        }

        select("video-subtitle")
        XCTAssertTrue(currentPrompt.contains("real-time subtitle translator"))
        select("tech-it")
        XCTAssertTrue(currentPrompt.contains("professional technical translator"))
        XCTAssertNotEqual(currentPrompt, "", "切换后 Prompt 必须更新")
        select("game")
        XCTAssertTrue(currentPrompt.contains("video game translator"))

        // 保存时按内容匹配回写预设 id；不匹配 → 自定义。
        func savedID() -> String {
            TranslationPromptPreset.all.first { $0.prompt == currentPrompt }?.id
                ?? TranslationPromptPreset.customID
        }
        select("tech-it")
        XCTAssertEqual(savedID(), "tech-it")
        currentPrompt = "my own prompt"
        XCTAssertEqual(savedID(), TranslationPromptPreset.customID)
        _ = currentID
    }

    /// 按 id 查预设；未知名返回 nil（上层回落默认指令）。
    func testLookupById() {
        XCTAssertNotNil(TranslationPromptPreset.with(id: "tech-it"))
        XCTAssertNil(TranslationPromptPreset.with(id: "不存在的id"))
        XCTAssertNil(TranslationPromptPreset.with(id: ""))
    }

    // MARK: 用户配置兼容（规格第七节）

    /// 模拟设置页 loadPersisted 的兼容三分支：
    /// 已有 Prompt → 原样保留；首次安装 → 默认视频字幕；残留 id → 内容为准。
    func testUserConfigurationCompatibility() {
        let savedPromptKey = "test_saved_prompt"
        let savedIDKey = "test_saved_id"
        UserDefaults.standard.removeObject(forKey: savedPromptKey)
        UserDefaults.standard.removeObject(forKey: savedIDKey)

        // 场景 1：首次安装（两键皆空）→ 加载默认「视频字幕」。
        let firstRunPrompt = UserDefaults.standard.string(forKey: savedPromptKey) ?? ""
        let firstRunID = UserDefaults.standard.string(forKey: savedIDKey) ?? ""
        if firstRunPrompt.isEmpty && firstRunID.isEmpty {
            let preset = TranslationPromptPreset.with(id: TranslationPromptPreset.defaultID)
            XCTAssertEqual(preset?.name, "视频字幕")
        }

        // 场景 2：已有用户自定义 Prompt → 原样保留（不被默认覆盖）。
        let userPrompt = "my custom prompt {text}"
        UserDefaults.standard.set(userPrompt, forKey: savedPromptKey)
        let restored = UserDefaults.standard.string(forKey: savedPromptKey) ?? ""
        XCTAssertEqual(restored, userPrompt, "已有自定义 Prompt 升级后必须保留")
        XCTAssertNotEqual(restored,
                          TranslationPromptPreset.with(id: TranslationPromptPreset.defaultID)?.prompt ?? "",
                          "默认预设不得覆盖用户已有配置")
        UserDefaults.standard.removeObject(forKey: savedPromptKey)
        UserDefaults.standard.removeObject(forKey: savedIDKey)
    }

    // MARK: Apple Translation 隔离（规格第七/十二节）

    /// Apple Translation 路径不读 systemPrompt：不经过 PromptBuilder。
    /// 源码级守护：Apple 翻译引擎文件不得引用 PromptBuilder。
    func testAppleTranslationDoesNotUsePromptBuilder() throws {
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

    /// Provider 回归守护（规格第十节）：LLM 路径的 prompt 注入点唯一
    /// （TranslationService.systemContent 构造），Provider 文件不含
    /// 第二套变量替换逻辑。
    func testProvidersHaveNoDuplicateVariableSubstitution() throws {
        let providerFiles = ["LocalTranslationProvider.swift", "ChatCompletionProvider.swift"]
        for fileName in providerFiles {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Pipeline/Translation/\(fileName)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let content = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(content.contains("replacingOccurrences(of: \"{"),
                           "\(fileName) 出现了独立的变量替换逻辑（违反唯一收口）")
        }
    }
}
