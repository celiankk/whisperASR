import XCTest
@testable import WhisperASR

// MARK: - 公共免 key 翻译通道单测
//
// 覆盖面：
// 1. Google 响应解析（多代形状：v1 嵌套 / v2 扁平 / 多段 / te=1 字典变体）；
// 2. 微软（Bing/Edge 同构）响应解析——含**纯元数据尾元素**的跳过
//    （实测中文目标语言时 Bing 会追加 inputTransliteration 元素，
//      误当结果会往译文里塞空串）；
// 3. 业务错误体（HTTP 200 + statusCode）到 TranslationError 的映射；
// 4. Bing 会话页参数解析（IG / data-iid / 防滥用三元组）；
// 5. URL 与请求构造、语言码映射、超长文本分片。
//
// 解析用的 payload 均为**实测抓取**（2026-09-11 本机直连），非构造样本。

final class FreeWebTranslationTests: XCTestCase {

    // MARK: - Google 解析

    func testGoogleV2FlatParsing() {
        // 实测：GET translate_a/t?client=dict-chrome-ex&q=Hello, world. → 此形状
        let json = #"[["你好世界。","en"]]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(FreeWebParsing.googleTranslation(from: any), "你好世界。")
        XCTAssertEqual(FreeWebParsing.googleDetectedLanguage(from: any), "en")
    }

    func testGoogleV1NestedParsing() {
        // v1 形状（多包一层 + 顶层语言码）。注：v1 端点本机被 Google 风控
        // 拦截（返回 HTML），此形状取自接口长期稳定结构，未能在本机实测。
        let json = #"[[["你好，世界。","Hello, world.",null,null,10]],null,"en",null,null,null,null,[]]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(FreeWebParsing.googleTranslation(from: any), "你好，世界。")
        XCTAssertEqual(FreeWebParsing.googleDetectedLanguage(from: any), "en")
    }

    func testGoogleV1MultiSegmentJoinsAll() {
        // v1 长句会被切成多段（[译文, 原文, …]），必须全部拼接而非只取首段。
        let json = #"[[["第一段。","one",null,null,10],["第二段。","two",null,null,10]],null,"en"]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(FreeWebParsing.googleTranslation(from: any), "第一段。第二段。")
    }

    func testGoogleDictionaryVariantParsing() {
        // te=1 变体：对象形态 sentences[].trans
        let json = #"{"sentences":[{"trans":"你好","orig":"Hello"},{"trans":"世界","orig":" world"}]}"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(FreeWebParsing.googleTranslation(from: any), "你好世界")
    }

    func testGoogleParsingRejectsUnrelatedJSON() {
        // 顶层语言码数组不能被误判成译文段。
        let json = #"["en","zh-CN"]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertNil(FreeWebParsing.googleTranslation(from: any))
    }

    /// v2 在**显式源语言**时返回扁平字符串数组（实测自带 lang 参数会改变形状）。
    ///
    /// 实测：`/translate_a/t?client=dict-chrome-ex&sl=en&tl=zh-CN&q=Hello`
    /// → `["你好"]`。而 `sl=auto` → `[["你好","en"]]`。
    /// 旧解析器要求每段至少两元，对这种形状返回 nil → 整句丢成 parseError。
    func testGoogleV2FlatStringArrayParsingWithExplicitSource() {
        let json = #"["你好"]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(FreeWebParsing.googleTranslation(from: any), "你好")
    }

    func testGoogleV2FlatMultiStringJoinsAll() {
        let json = #"["第一段。","第二段。"]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(FreeWebParsing.googleTranslation(from: any), "第一段。第二段。")
    }

    // MARK: 不可见字符清洗

    /// Google 在数字/单位边界插 U+200B（零宽空格）——实测
    /// "第三季度营收同比增长 12.5%，" → `12.5%\u{200B}\u{200B}year-over-year`。
    /// 这些字符肉眼不可见但占字符位、`trimmingCharacters` 清不掉（在中间），
    /// 且会随复制/SRT 导出/历史 JSON 落盘。
    func testZeroWidthSpaceIsStripped() {
        let raw = #"[[["Revenue grew 12.5%\u200B\u200Byear-over-year.","第三季度营收同比增长 12.5%，",null,null,3]],null,"zh-CN"]"#
        let any = try! JSONSerialization.jsonObject(with: Data(raw.utf8))
        let out = try! XCTUnwrap(FreeWebParsing.googleTranslation(from: any))
        XCTAssertFalse(out.unicodeScalars.contains { $0.value == 0x200B },
                       "零宽空格必须被清掉，实际: \(out.debugDescription)")
        XCTAssertEqual(out, "Revenue grew 12.5%year-over-year.")
        // 清洗后长度不再被隐形字符撑大（"…12.5%year-over-year." = 33 字符）。
        XCTAssertEqual(out.count, 33)
    }

    func testFlatPathAlsoStripsZeroWidth() {
        let raw = #"["Revenue grew 12.5%\u200B\u200Byear-over-year."]"#
        let any = try! JSONSerialization.jsonObject(with: Data(raw.utf8))
        let out = try! XCTUnwrap(FreeWebParsing.googleTranslation(from: any))
        XCTAssertFalse(out.unicodeScalars.contains { $0.value == 0x200B },
                       "扁平路径（v2 显式源语言）同样要清洗")
    }

    func testSanitizeRemovesBidiAndBomButKeepsContent() {
        // 双向控制符/BOM 一并清掉；正常文本（含 CJK、emoji、全角）不受影响。
        XCTAssertEqual(FreeWebParsing.sanitizeTranslation("a\u{200E}b\u{202A}c\u{FEFF}d"), "abcd")
        XCTAssertEqual(FreeWebParsing.sanitizeTranslation("正常文本 😀 １２３"), "正常文本 😀 １２３")
        XCTAssertEqual(FreeWebParsing.sanitizeTranslation(""), "")
    }

    func testGoogleDetectedLanguageIgnoresSourceText() {
        // v2 段的第二项是语言码；v1 段第二项是原文，不能当语言码。
        XCTAssertTrue(FreeWebParsing.isLanguageCode("en"))
        XCTAssertTrue(FreeWebParsing.isLanguageCode("zh-Hans"))
        XCTAssertFalse(FreeWebParsing.isLanguageCode("Hello, world."))
    }

    // MARK: - 微软解析

    func testMicrosoftSingleResultParsing() {
        // 实测：Bing ttranslatev3 英文 → 中文
        let json = #"[{"translations":[{"text":"你好，世界。","to":"zh-Hans","transliteration":{"text":"Nǐ hǎo, shìjiè.","script":"Latn"}}],"usedLLM":true,"detectedLanguage":{"language":"en"}}]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let result = FreeWebParsing.microsoftResult(from: any, count: 1)
        XCTAssertEqual(result?.texts, ["你好，世界。"])
        XCTAssertEqual(result?.detected, "en")
    }

    func testMicrosoftSkipsTrailingMetadataElement() {
        // 实测：中文 → 英文时 Bing 追加纯元数据元素（无 translations）。
        // 若不过滤，会多出一条空译文并把结果整体错位。
        let json = #"[{"translations":[{"text":"The weather is very nice today.","to":"en"}],"usedLLM":true,"detectedLanguage":{"language":"zh-Hans"}},{"inputTransliteration":"Jīntiān tiānqì hěn hǎo.","script":"Latn"}]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let result = FreeWebParsing.microsoftResult(from: any, count: 1)
        XCTAssertEqual(result?.texts, ["The weather is very nice today."])
        XCTAssertEqual(result?.detected, "zh-Hans")
    }

    func testMicrosoftPadsToRequestedCount() {
        // 请求多段但响应不足时补空串，保证与输入行对齐（不串句）。
        let json = #"[{"translations":[{"text":"唯一译文","to":"zh-Hans"}]}]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(FreeWebParsing.microsoftResult(from: any, count: 3)?.texts,
                       ["唯一译文", "", ""])
    }

    func testMicrosoftErrorMapping() {
        // 实测：失效 token 返回 HTTP 200 + 此业务错误体。
        let json = #"{"statusCode":205,"errorMessage":""}"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let error = FreeWebParsing.microsoftError(from: any) else {
            return XCTFail("205 应映射为错误")
        }
        guard case .authFailed = error else {
            return XCTFail("205 应映射为 authFailed（触发会话刷新重试），实际 \(error)")
        }
        XCTAssertFalse(error.isRetryableOnFreeChannel, "会话失效靠刷新解决，不靠退避重试")
    }

    func testMicrosoftRateLimitMappingIsRetryable() {
        let json = #"{"statusCode":429,"errorMessage":"slow down"}"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let error = FreeWebParsing.microsoftError(from: any) else {
            return XCTFail("429 应映射为错误")
        }
        guard case .rateLimited = error else {
            return XCTFail("429 应映射为 rateLimited，实际 \(error)")
        }
        XCTAssertTrue(error.isRetryableOnFreeChannel, "免费端点 429 应退避重试")
    }

    func testMicrosoftNoErrorOnNormalResult() {
        let json = #"[{"translations":[{"text":"你好","to":"zh-Hans"}]}]"#
        let any = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertNil(FreeWebParsing.microsoftError(from: any))
    }

    // MARK: - Bing 会话页解析

    /// 实测页面片段（保留真实结构，省略无关 HTML）。
    private let bingPageFixture = #"""
    <html><body><div id="rich_tta" data-iid="translator.5025"></div>
    <script>var _G = {IG:"07AAFB5AD03C4FFDA389A7A59E0BA9A5",EventID:"x"};</script>
    <div data-iid="translator.5026"></div>
    <script>var params_AbusePreventionHelper = [1789064879021,"xRfPn4CY9nxm_Bj2nzNR7N-5psrG4-O-",3600000];</script>
    <div data-iid="translator.5028"></div>
    </body></html>
    """#

    func testBingSessionParsing() throws {
        let session = try BingSessionProvider.parse(bingPageFixture)
        XCTAssertEqual(session.ig, "07AAFB5AD03C4FFDA389A7A59E0BA9A5")
        XCTAssertEqual(session.iid, "translator.5028", "多实例应取最后一个 data-iid")
        XCTAssertEqual(session.key, "1789064879021")
        XCTAssertEqual(session.token, "xRfPn4CY9nxm_Bj2nzNR7N-5psrG4-O-")
        // 3600000ms × 0.85 ≈ 51 分钟，须落在请求时刻之后且不超过封顶值。
        let remaining = session.expiresAt.timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 60)
        XCTAssertLessThanOrEqual(remaining, 3600)
    }

    func testBingSessionParsingFailsOnChangedPage() {
        XCTAssertThrowsError(try BingSessionProvider.parse("<html>nothing here</html>")) { error in
            guard case TranslationError.endpointBlocked = error else {
                return XCTFail("页面结构变更应报 endpointBlocked（便于诊断），实际 \(error)")
            }
        }
    }

    func testBingSessionIgCapturedNotEventID() {
        // IG 正则不能贪婪吞掉后面的字段（曾用 [^"]+ 的边界必须严格到引号）。
        let session = try? BingSessionProvider.parse(bingPageFixture)
        XCTAssertEqual(session?.ig.count, 32)
    }

    // MARK: - URL 与请求构造

    func testGoogleURLConstructionEncodesSpecialCharacters() {
        let text = "a+b&c=d 中文"
        let url = FreeWebTransport.googleURL(text, channel: .googleV2, source: "", target: "zh-CN")
        XCTAssertNotNil(url)
        // 文本必须整体落在 q 参数里（+ / & 不能被解释成参数分隔符）。
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "q" }?.value, text)
        XCTAssertEqual(query.first { $0.name == "client" }?.value, "dict-chrome-ex")
        XCTAssertEqual(query.first { $0.name == "sl" }?.value, "auto", "空源语言必须是 auto")
    }

    /// 线上格式（不只是解析回来的值）：`+` 必须编成 %2B。
    ///
    /// 只断言 `queryItems` 往返会给出**虚假保证**——URLComponents 把 `+`
    /// 原样留在 query 里，往返解析自然还是 "+"，但 Google/Bing 按表单语义
    /// 把 `+` 解成空格，原文 "C++" 到服务端就变成 "C"。
    func testGoogleURLPercentEncodesPlusOnTheWire() {
        let url = FreeWebTransport.googleURL("C++ 1+1", channel: .googleV1,
                                            source: "en", target: "zh-CN")
        let wire = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery ?? ""
        XCTAssertTrue(wire.contains("q=C%2B%2B%201%2B1"),
                      "`+` 必须编成 %2B，实际: \(wire)")
        XCTAssertFalse(wire.contains("q=C++"),
                       "裸 `+` 会被服务端解成空格，实际: \(wire)")
    }

    /// 表单体（Bing）同理：Content-Type 是 x-www-form-urlencoded。
    func testStrictQueryEncodingCoversFormBody() {
        let body = FreeWebTransport.encodeQuery([
            ("fromLang", "auto-detect"),
            ("text", "C++ 与 a&b"),
            ("to", "en"),
        ])
        XCTAssertTrue(body.contains("text=C%2B%2B%20%E4%B8%8E%20a%26b"),
                      "`+` 编成 %2B、`&` 编成 %26，实际: \(body)")
        // 参数分隔符仍只有真正的 & 分隔（3 个参数）。
        XCTAssertEqual(body.components(separatedBy: "&").count, 3)
    }

    func testGoogleV1URLUsesGtxClient() {
        let url = FreeWebTransport.googleURL("hi", channel: .googleV1, source: "en", target: "ja")
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "client" }?.value, "gtx")
        XCTAssertEqual(query.first { $0.name == "dt" }?.value, "t")
        XCTAssertEqual(query.first { $0.name == "sl" }?.value, "en")
    }

    func testBingURLCarriesSessionIdentifiers() {
        let session = BingTranslationSession(
            ig: "ABC", iid: "translator.5028", key: "1", token: "t",
            expiresAt: Date().addingTimeInterval(600))
        let url = FreeWebTransport.bingURL(session: session)
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "IG" }?.value, "ABC")
        XCTAssertEqual(query.first { $0.name == "IID" }?.value, "translator.5028")
        XCTAssertEqual(query.first { $0.name == "isVertical" }?.value, "1")
    }

    // MARK: - 语言码映射

    func testGoogleLanguageCodeMapping() {
        // Google 用 zh-CN / zh-TW，不接受 BCP-47 的 zh-Hans / zh-Hant。
        XCTAssertEqual(FreeWebParsing.googleLanguageCode("zh-Hans"), "zh-CN")
        XCTAssertEqual(FreeWebParsing.googleLanguageCode("zh-Hant"), "zh-TW")
        XCTAssertEqual(FreeWebParsing.googleLanguageCode("ja"), "ja")
        XCTAssertEqual(FreeWebParsing.googleLanguageCode(""), "en")
    }

    func testMicrosoftLanguageCodeKeepsBCP47() {
        XCTAssertEqual(FreeWebParsing.microsoftLanguageCode("zh-Hans"), "zh-Hans")
        XCTAssertEqual(FreeWebParsing.microsoftLanguageCode(""), "en")
    }

    // MARK: - 分片

    func testChunkKeepsShortTextIntact() {
        XCTAssertEqual(FreeWebTransport.chunk("短句。"), ["短句。"])
    }

    func testChunkSplitsLongTextAndPreservesContent() {
        let sentence = "这是一个用于测试分片的长句子。"
        let text = String(repeating: sentence, count: 300)  // ≫ limit
        let chunks = FreeWebTransport.chunk(text, limit: 300)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text, "分片不得丢字或改序")
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 300 * 2 }, "单片不得超过硬上限")
    }

    // MARK: - 通道元数据

    func testModeToChannelConsistency() {
        // 每个免 key 模式都必须解析出通道，且 Kind 与通道一一对应（防配错）。
        for mode in TranslationMode.allCases {
            let channel = mode.freeWebChannel
            XCTAssertEqual(channel != nil, mode.isFreeWebChannel,
                           "\(mode) 的 freeWebChannel 与 isFreeWebChannel 不一致")
            guard let channel else { continue }
            let provider = FreeWebTranslationProvider(channel: channel)
            XCTAssertEqual(provider.kind, channel.providerKind)
        }
    }

    func testManagerRoutesEveryFreeModeToItsOwnProvider() {
        let cases: [(TranslationMode, TranslationProviderKind)] = [
            (.googleV1, .googleV1),
            (.googleV2, .googleV2),
            (.microsoft, .microsoft),
        ]
        for (mode, kind) in cases {
            XCTAssertEqual(TranslationManager.provider(for: mode).kind, kind,
                           "\(mode) 必须路由到 \(kind)")
        }
    }

    func testFreeModesAreDistinctFromExistingModes() {
        // 新增通道不得改变既有映射（本地/在线/Apple 行为回归保护）。
        XCTAssertEqual(TranslationManager.provider(for: .localModel).kind, .lmStudio)
        XCTAssertEqual(TranslationManager.provider(for: .onlineAPI).kind, .onlineAPI)
        XCTAssertEqual(TranslationManager.provider(for: .apple).kind, .apple)
    }

    // MARK: - 实时连通冒烟（网络不可用时跳过，其余失败即真 bug）

    func testLiveGoogleV2Translation() async throws {
        try await assertLiveTranslation(mode: .googleV2)
    }

    func testLiveMicrosoftTranslation() async throws {
        try await assertLiveTranslation(mode: .microsoft)
    }

    func testLiveGoogleV1FallsBackWhenBlocked() async throws {
        // v1 在被风控拦截时应回落 v2 而不是直接失败；两者都不可用才跳过。
        try await assertLiveTranslation(mode: .googleV1)
    }

    /// 跨批次保序：并发窗口是 4，喂 6 行会走「第一批 4 行 + 第二批 2 行」，
    /// 结果必须按输入下标严格归位（`output[offset + index]`），不得因
    /// 完成顺序不同而错位。这是本 Provider 最容易写错的地方（分块下标）。
    func testLiveMultiLineOrderingAcrossBatches() async throws {
        let inputs = ["Hello", "Goodbye", "Thank you", "Good morning", "See you", "Good night"]
        // 按位置逐条校验译文里必须出现的特征字——比"互不相同"更准：
        // Goodbye 与 See you 的中文都可能译作"再见"（合法重复），
        // 用去重判错位会误报（本测试初版就这么错过一次）。
        let expectedMarkers = ["你好", "再见", "谢", "早", "再见", "晚"]
        let provider = FreeWebTranslationProvider(channel: .googleV2)
        do {
            let result = try await provider.translate(
                TranslationRequest(texts: inputs, targetLanguage: "zh-Hans"))
            XCTAssertEqual(result.texts.count, inputs.count, "译文数量必须与输入一致")
            for (index, text) in result.texts.enumerated() {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty,
                               "第 \(index + 1) 行为空（可能丢失）：\(inputs[index])")
                XCTAssertTrue(text.contains(expectedMarkers[index]),
                              "第 \(index + 1) 行错位：期望含「\(expectedMarkers[index])」，"
                              + "实际「\(text)」（输入 \(inputs[index])）")
            }
        } catch let error as TranslationError {
            switch error {
            case .transport, .endpointBlocked:
                throw XCTSkip("网络不可达，跳过实时冒烟：\(error.localizedDescription)")
            case .rateLimited:
                throw XCTSkip("公共端点限流，跳过实时冒烟：\(error.localizedDescription)")
            default:
                XCTFail("多行翻译失败：\(error.localizedDescription)")
            }
        }
    }

    /// 单行失败不得牵连同批兄弟行（非抛错任务组的核心语义）。
    /// 用真实通道验证：把首行设成超长无边界文本触发分片，其余行正常，
    /// 断言正常行仍然拿到译文（而不是整批抛错）。
    func testLivePartialFailureKeepsSiblingResults() async throws {
        // 首行远超 1500 字符触发放大路径；即便该行最终失败，后两行也该成功。
        let longLine = String(repeating: "A", count: 4000)
        let inputs = [longLine, "Hello", "Goodbye"]
        let provider = FreeWebTranslationProvider(channel: .googleV2)
        do {
            let result = try await provider.translate(
                TranslationRequest(texts: inputs, targetLanguage: "zh-Hans"))
            XCTAssertEqual(result.texts.count, inputs.count)
            if result.texts[0].isEmpty {
                // 首行失败被容忍——兄弟行必须仍有结果。
                XCTAssertFalse(result.texts[1].isEmpty, "首行失败时第二行不应被牵连")
                XCTAssertFalse(result.texts[2].isEmpty, "首行失败时第三行不应被牵连")
            }
        } catch let error as TranslationError {
            switch error {
            case .transport, .endpointBlocked, .rateLimited:
                throw XCTSkip("网络不可达/限流，跳过：\(error.localizedDescription)")
            default:
                XCTFail("部分行失败导致整批抛错（兄弟结果被丢弃）：\(error.localizedDescription)")
            }
        }
    }

    /// 真实网络往返：成功即验证「URL 构造 + 会话 + 解析」全链路。
    /// 仅传输层错误（无网络/被墙）与公共端点限流跳过；解析或业务错误一律
    /// fail——否则解析器坏了也会显示成「环境问题」而被放过。
    /// `.rateLimited` 也跳过：Google/Bing 的免 key 端点按 IP 限流（HTTP 429、
    /// google.com/sorry），属于环境状态而非代码缺陷，判 fail 会让测试套件
    /// 在正常使用后（或连续跑几次测试后）无故变红。本文件其余实网用例
    ///（多行保序 / 部分失败）本就按同样口径跳过，此处与它们对齐。
    private func assertLiveTranslation(mode: TranslationMode,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) async throws {
        guard let channel = mode.freeWebChannel else {
            return XCTFail("\(mode) 不是免 key 通道", file: file, line: line)
        }
        let provider = FreeWebTranslationProvider(channel: channel)
        do {
            let result = try await provider.translate(
                TranslationRequest(text: "Hello, world.", targetLanguage: "zh-Hans"))
            let text = result.texts.first ?? ""
            XCTAssertFalse(text.isEmpty, "空译文", file: file, line: line)
            XCTAssertTrue(text.contains("你") || text.contains("世") || text.contains("界")
                          || text.contains("您好"),
                          "译文不含中文，疑似解析错位：\(text)", file: file, line: line)
        } catch let error as TranslationError {
            switch error {
            case .transport, .endpointBlocked:
                throw XCTSkip("网络不可达，跳过实时冒烟：\(error.localizedDescription)")
            case .rateLimited:
                throw XCTSkip("公共端点限流，跳过实时冒烟：\(error.localizedDescription)")
            default:
                XCTFail("\(mode) 实时翻译失败：\(error.localizedDescription)", file: file, line: line)
            }
        }
    }
}

// MARK: - 反滥用拦截识别（错误文案与重试策略）

final class AbuseBlockDetectionTests: XCTestCase {

    private let googleSorry = Data("""
    <html><head><meta http-equiv="content-type" content="text/html; charset=utf-8"/>
    <title>Sorry...</title></head><body><div><h1>We're sorry...</h1>
    <p>... but your computer or network may be sending automated queries.
    To protect our users, we can't process your request right now.</p></div></body></html>
    """.utf8)

    func testDetectsGoogleSorryPage() {
        let msg = FreeWebTransport.abuseBlockDescription(status: 429, data: googleSorry)
        let text = try! XCTUnwrap(msg)
        XCTAssertTrue(text.contains("出口 IP"), "应指出是出口 IP 问题：\(text)")
        XCTAssertTrue(text.contains("微软"), "应给出可操作的替代通道")
        XCTAssertTrue(text.contains("代理"), "应提示可配代理")
        // 不得把 HTML 原样塞进用户可见文案。
        XCTAssertFalse(text.contains("<!DOCTYPE"))
        XCTAssertFalse(text.contains("<html"))
    }

    func testDetects302SorryRedirectBody() {
        let body = Data("""
        <HTML><HEAD><TITLE>302 Moved</TITLE></HEAD><BODY>
        <A HREF="https://www.google.com/sorry/index?continue=https://translate.googleapis.com/">
        """.utf8)
        XCTAssertNotNil(FreeWebTransport.abuseBlockDescription(status: 302, data: body))
    }

    func testIgnoresNormalJSON() {
        let json = Data(#"[["你好","en"]]"#.utf8)
        XCTAssertNil(FreeWebTransport.abuseBlockDescription(status: 200, data: json),
                     "正常 JSON 不得被判为拦截")
    }

    func testIgnoresEmptyBody() {
        XCTAssertNil(FreeWebTransport.abuseBlockDescription(status: 500, data: Data()))
    }

    func testReadablePreviewStripsHTMLTags() {
        let preview = FreeWebTransport.readablePreview(googleSorry)
        XCTAssertFalse(preview.contains("<"), "展示预览必须去掉标签：\(preview)")
        XCTAssertTrue(preview.contains("automated queries") || preview.contains("Sorry"))
    }

    func testReadablePreviewKeepsJSONIntact() {
        let json = Data(#"{"statusCode":205,"errorMessage":"session"}"#.utf8)
        let preview = FreeWebTransport.readablePreview(json)
        XCTAssertEqual(preview, #"{"statusCode":205,"errorMessage":"session"}"#,
                       "JSON 不该被去标签正则破坏（含 < > 的场景才处理）")
    }

    func testReadablePreviewTruncates() {
        let long = Data(String(repeating: "x", count: 500).utf8)
        XCTAssertLessThanOrEqual(FreeWebTransport.readablePreview(long, limit: 160).count, 160)
    }
}

// MARK: - translate-pa 网关（Google 免 key 通道的现行端点）

/// 背景：旧的 `translate_a/*` 免 key 端点已被 Google 反滥用墙收紧（实测
/// 429 / 302→google.com/sorry / 403，且换出口 IP 无效——日本/香港/台湾
/// 三个节点全 429）。Google 自家网站翻译控件（te_lib）用的
/// `translate-pa.googleapis.com/v1/translateHtml` 仍可用，实测 200。
final class GoogleTranslatePATests: XCTestCase {

    func testParsesPairedArrays() throws {
        // 实测响应形状：[[译文…], [检测语言…]]
        let json = try JSONSerialization.jsonObject(
            with: Data(#"[["你好世界。"],["en"]]"#.utf8))
        let result = try FreeWebParsing.translatePAResult(
            from: json, texts: ["Hello, world."], sentIndices: [0])
        XCTAssertEqual(result.texts, ["你好世界。"])
        XCTAssertEqual(result.detected, "en")
    }

    func testDetectedLanguageMayBeAbsent() throws {
        // 显式源语言时实测第二项缺失——不得因此报错。
        let json = try JSONSerialization.jsonObject(
            with: Data(#"[["The weather is great today."]]"#.utf8))
        let result = try FreeWebParsing.translatePAResult(
            from: json, texts: ["今天天气很好"], sentIndices: [0])
        XCTAssertEqual(result.texts, ["The weather is great today."])
        XCTAssertNil(result.detected)
    }

    /// 空串元素会被网关 400 拒绝，所以发送前剔除、结果按**原下标**回填。
    /// 回填错位会让译文落到别的句子上（批量路径下是静默错配）。
    func testSkipsEmptyAndRestoresPositions() throws {
        let texts = ["", "B", "", "D"]
        let sentIndices = [1, 3]           // 实际发送的下标
        let json = try JSONSerialization.jsonObject(
            with: Data(#"[["乙","丁"],["en","en"]]"#.utf8))
        let result = try FreeWebParsing.translatePAResult(
            from: json, texts: texts, sentIndices: sentIndices)
        XCTAssertEqual(result.texts, ["", "乙", "", "丁"],
                       "译文必须回填到原始下标，空位保持空串")
    }

    func testHTTPEscapedEntitiesAreDecoded() throws {
        // 实测：输入 "a < b & c" → 返回 "a &lt; b &amp; c"
        let json = try JSONSerialization.jsonObject(
            with: Data(#"[["a &lt; b &amp; c 100%"],["en"]]"#.utf8))
        let result = try FreeWebParsing.translatePAResult(
            from: json, texts: ["a < b & c 100%"], sentIndices: [0])
        XCTAssertEqual(result.texts, ["a < b & c 100%"],
                       "HTML 实体必须反转义，否则用户看到 &lt; 字面量")
    }

    func testUnescapeHandlesNumericEntities() {
        XCTAssertEqual(FreeWebParsing.unescapeHTMLEntities("&#39;a&#39;"), "'a'")
        XCTAssertEqual(FreeWebParsing.unescapeHTMLEntities("&#x27;a&#x27;"), "'a'")
        XCTAssertEqual(FreeWebParsing.unescapeHTMLEntities("&quot;q&quot;"), "\"q\"")
    }

    /// `&amp;lt;` 应解成字面 `&lt;`，不能二次解码成 `<`。
    func testUnescapeDoesNotDoubleDecode() {
        XCTAssertEqual(FreeWebParsing.unescapeHTMLEntities("&amp;lt;"), "&lt;",
                       "二次解码会把已经转义的实体错误还原")
    }

    func testUnescapeLeavesBareAmpersand() {
        XCTAssertEqual(FreeWebParsing.unescapeHTMLEntities("A & B"), "A & B")
        XCTAssertEqual(FreeWebParsing.unescapeHTMLEntities("100% &"), "100% &")
    }

    func testErrorBodyBecomesAPIError() throws {
        // 网关错误体：[code, "message", …]（首元素是数字）
        let json = try JSONSerialization.jsonObject(
            with: Data(#"[3,"Request contains an invalid argument."]"#.utf8))
        XCTAssertThrowsError(try FreeWebParsing.translatePAResult(
            from: json, texts: ["x"], sentIndices: [0])) { error in
            guard case TranslationError.apiFailed(let msg) = error else {
                return XCTFail("应抛 apiFailed，实际 \(error)")
            }
            XCTAssertTrue(msg.contains("invalid argument"), msg)
        }
    }

    // MARK: 实网冒烟（走应用真实传输层）

    func testLiveTranslatePAEndpoint() async throws {
        do {
            let result = try await FreeWebTransport.translatePAOnce(
                ["Hello, world."], source: "", target: "zh-Hans")
            let text = try XCTUnwrap(result.texts.first)
            XCTAssertFalse(text.isEmpty, "空译文")
            XCTAssertTrue(text.contains("你") || text.contains("世") || text.contains("界"),
                          "译文不含中文，疑似解析错位：\(text)")
        } catch let error as TranslationError {
            switch error {
            case .transport, .endpointBlocked:
                throw XCTSkip("网络不可达/端点被拦，跳过：\(error.localizedDescription)")
            case .rateLimited:
                throw XCTSkip("限流，跳过：\(error.localizedDescription)")
            default:
                XCTFail("translate-pa 实时翻译失败：\(error.localizedDescription)")
            }
        }
    }

    func testLiveTranslatePABatchKeepsOrder() async throws {
        let inputs = ["Hello", "Goodbye", "Thank you"]
        do {
            let result = try await FreeWebTransport.translatePAOnce(
                inputs, source: "", target: "zh-Hans")
            XCTAssertEqual(result.texts.count, inputs.count, "批量返回长度必须与输入一致")
            XCTAssertTrue(result.texts[0].contains("你"), "第 1 条错位：\(result.texts)")
            XCTAssertTrue(result.texts[1].contains("再见"), "第 2 条错位：\(result.texts)")
        } catch let error as TranslationError {
            switch error {
            case .transport, .endpointBlocked, .rateLimited:
                throw XCTSkip("跳过：\(error.localizedDescription)")
            default:
                XCTFail("批量翻译失败：\(error.localizedDescription)")
            }
        }
    }
}
