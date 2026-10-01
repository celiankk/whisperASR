import XCTest
@testable import WhisperASR

/// Apple Speech 语言 id 的身份归一（回归测试）。
///
/// 实测本机：SpeechTranscriber.installedLocales 全部返回下划线形态
/// （zh_CN / en_US / yue_CN），而配置与 Locale(identifier:) 常见写法是
/// 连字符（zh-CN），Apple 的等价解析还会补出脚本（zh-Hans-CN → zh_CN）。
/// 曾经用精确字符串比较，导致设置页把当前语言标成「未安装」、
/// 状态检测误判 needResource、菜单栏勾不上。
final class AppleLocaleIdentityTests: XCTestCase {

    func testHyphenAndUnderscoreFormsAreTheSameLocale() {
        XCTAssertTrue(AppleLanguageManager.isSameLocale("zh-CN", "zh_CN"))
        XCTAssertTrue(AppleLanguageManager.isSameLocale("en-US", "en_US"))
        XCTAssertTrue(AppleLanguageManager.isSameLocale("yue-CN", "yue_CN"))
    }

    func testScriptSubtagDoesNotSplitIdentity() {
        XCTAssertTrue(AppleLanguageManager.isSameLocale("zh-Hans-CN", "zh_CN"))
        XCTAssertTrue(AppleLanguageManager.isSameLocale("zh-Hant-TW", "zh_TW"))
    }

    func testRegionStillDistinguishesLocales() {
        // 同语言不同地区必须仍是两种资源（zh_CN ≠ zh_TW ≠ zh_HK）。
        XCTAssertFalse(AppleLanguageManager.isSameLocale("zh_CN", "zh_TW"))
        XCTAssertFalse(AppleLanguageManager.isSameLocale("zh_CN", "zh_HK"))
        XCTAssertFalse(AppleLanguageManager.isSameLocale("pt_BR", "pt_PT"))
        // 粤语（yue_CN）不能被当成普通话（zh_CN）。
        XCTAssertFalse(AppleLanguageManager.isSameLocale("yue_CN", "zh_CN"))
    }

    func testEmptyAndGarbageInputsNeverMatch() {
        XCTAssertFalse(AppleLanguageManager.isSameLocale("", ""))
        XCTAssertFalse(AppleLanguageManager.isSameLocale("", "zh_CN"))
        // 无法解析的串退化为自身，仍不会与别的语言误判相同。
        XCTAssertFalse(AppleLanguageManager.isSameLocale("zz_ZZ", "zh_CN"))
    }

    func testMatchKeyIsStableAcrossForms() {
        XCTAssertEqual(AppleLanguageManager.matchKey("zh-CN"),
                       AppleLanguageManager.matchKey("zh_CN"))
        XCTAssertEqual(AppleLanguageManager.matchKey("zh-Hans-CN"),
                       AppleLanguageManager.matchKey("zh_CN"))
    }
}
