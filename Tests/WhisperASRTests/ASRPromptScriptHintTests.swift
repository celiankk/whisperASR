import XCTest
@testable import WhisperASR

// MARK: - 简体脚本提示的合并语义
//
// 背景：whisper 在 language=zh 下不区分简繁，实测普通话默认输出繁体
//（"今天天氣很好"），端到端工作台量到平均字错率 23.8% → 加入脚本提示后 3.9%。
// 该提示**始终注入**（与"启用提示词"开关无关），因为这是语言正确性问题，
// 不是可选优化——绑在默认关闭的开关上等于所有新用户开箱拿到繁体。
//
// 这里锁定合并语义：它决定每次识别真正送进 initial_prompt 的内容，
// 写错会静默影响全部中文识别。
final class ASRPromptScriptHintTests: XCTestCase {

    private let hint = "请用简体中文转写。"

    // MARK: 始终注入

    func testEmptyBaseStillGetsHint() {
        XCTAssertEqual(ASRPromptManager.mergedPrompt(base: nil), hint,
                       "用户没填任何内容时也要注入脚本提示（这是默认路径）")
        XCTAssertEqual(ASRPromptManager.mergedPrompt(base: ""), hint)
        XCTAssertEqual(ASRPromptManager.mergedPrompt(base: "   \n "), hint,
                       "纯空白视同空")
    }

    // MARK: 与用户内容合并

    func testUserContentTakesPrecedenceOrder() {
        let merged = ASRPromptManager.mergedPrompt(base: "以下是技术会议常见词汇：架构、部署")
        XCTAssertTrue(merged.hasPrefix("以下是技术会议常见词汇"), "用户内容在前：\(merged)")
        XCTAssertTrue(merged.hasSuffix(hint), "脚本提示在后：\(merged)")
    }

    func testNoDuplicateSentenceTerminator() {
        // 用户内容已以句号结尾时不应出现「。。」
        let merged = ASRPromptManager.mergedPrompt(base: "以下是技术词汇。")
        XCTAssertFalse(merged.contains("。。"), "不得出现连续句号：\(merged)")
        XCTAssertTrue(merged.contains("技术词汇。" + hint))
    }

    func testDoesNotDuplicateHintWhenUserAlreadyWroteIt() {
        // 用户自定义提示里已包含同一句 → 不重复追加
        let base = "以下是技术词汇。" + hint
        let merged = ASRPromptManager.mergedPrompt(base: base)
        let occurrences = merged.components(separatedBy: hint).count - 1
        XCTAssertEqual(occurrences, 1, "脚本提示不应重复出现：\(merged)")
    }

    // MARK: 内容完整性

    func testBaseContentIsPreservedVerbatim() {
        let base = "API、SDK、commit、merge、sprint"
        let merged = ASRPromptManager.mergedPrompt(base: base)
        XCTAssertTrue(merged.contains(base), "用户内容必须原样保留：\(merged)")
    }

    func testHintIsStableAndSimplified() {
        // 提示本身必须是简体（它的作用就是给解码器简体字形参照）
        XCTAssertEqual(hint, "请用简体中文转写。")
        XCTAssertTrue(ASRPromptManager.mergedPrompt(base: nil).contains("简"),
                      "必须含「简」字作为简体参照")
    }
}
