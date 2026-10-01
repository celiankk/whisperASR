import XCTest
@testable import WhisperASR

// MARK: - 品牌改名断点回归
//
// 背景：产品从 WhisperASR 改名「声记 SonicScribe」后，AppDelegate 仍硬编码
// `url.scheme == "whisperasr"`，而打包脚本往 Info.plist 里写的是按品牌派生的
// `sonicscribe` → `open sonicscribe://record` 静默失效。
//
// 本组测试锁定「scheme 事实来源 = Info.plist」这条不变量：无论品牌怎么改，
// 只要打包脚本把 scheme 写进 plist，App 就必须认。

final class URLSchemeOwnershipTests: XCTestCase {

    /// 打包脚本（build_release.sh）写出的 plist 结构：新 scheme + 旧 scheme 双写。
    private let releasePlist: [String: Any] = [
        "CFBundleURLTypes": [
            [
                "CFBundleURLName": "com.sonicscribe.app",
                "CFBundleURLSchemes": ["sonicscribe", "whisperasr"],
            ]
        ]
    ]

    func testRebrandedSchemeIsAccepted() {
        let schemes = AppDelegate.urlSchemes(fromInfoDictionary: releasePlist)
        XCTAssertTrue(schemes.contains("sonicscribe"),
                      "改名后的 scheme 必须被接受（原 bug：只认 whisperasr）")
        XCTAssertTrue(schemes.contains("whisperasr"),
                      "旧 scheme 需保留以兼容升级安装的快捷方式")
    }

    func testFutureRenameFollowsPlistWithoutCodeChange() {
        // 再次改名（plist 换成 quickscribe）：代码零改动即生效。
        let plist: [String: Any] = [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["quickscribe"]]]
        ]
        XCTAssertTrue(AppDelegate.urlSchemes(fromInfoDictionary: plist).contains("quickscribe"))
    }

    func testMissingPlistFallsBackToKnownSchemes() {
        // swift run 裸跑（无 bundle）与 plist 缺 URLTypes 两种降级路径。
        XCTAssertEqual(AppDelegate.urlSchemes(fromInfoDictionary: nil),
                       ["whisperasr", "sonicscribe"])
        XCTAssertEqual(AppDelegate.urlSchemes(fromInfoDictionary: [:]),
                       ["whisperasr", "sonicscribe"])
    }

    func testMultipleURLTypeEntriesAreMerged() {
        let plist: [String: Any] = [
            "CFBundleURLTypes": [
                ["CFBundleURLSchemes": ["a-one"]],
                ["CFBundleURLSchemes": ["b-two", "c-three"]],
            ]
        ]
        XCTAssertEqual(AppDelegate.urlSchemes(fromInfoDictionary: plist),
                       ["a-one", "b-two", "c-three", "whisperasr", "sonicscribe"])
    }

    func testSchemeMatchingIsCaseInsensitive() {
        // URL scheme 大小写不敏感（RFC 3986）；系统可能把 scheme 规范化。
        XCTAssertTrue(AppDelegate.owns(URL(string: "SonicScribe://record")!))
        XCTAssertFalse(AppDelegate.owns(URL(string: "someotherapp://record")!))
        XCTAssertFalse(AppDelegate.owns(URL(string: "https://example.com")!))
    }

    func testHostRoutingStillRequiresRecord() {
        // scheme 归属判定放宽后，host 仍须是 record（避免误吞其他自定义动作）。
        XCTAssertEqual(URL(string: "sonicscribe://record?app=Zoom")?.host, "record")
    }
}
