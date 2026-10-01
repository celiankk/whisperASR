import Foundation

// MARK: - 公共免 API Key 翻译通道（FreeWebTranslationProvider）
//
// 三条「不需要 Key / 账号 / 自建服务」的公共在线翻译通道，作为
// TranslationProvider 的独立实现接入 TranslationManager 统一调度：
//
//   1. Google v1 —— `translate_a/single`（client=gtx，Chrome 网页版同源）
//   2. Google v2 —— `translate_a/t`（client=dict-chrome-ex，Chrome 词典
//      扩展同源）
//   3. 微软 —— Bing 网页翻译会话（`bing.com/translator` 取 IG + 防滥用
//      token/key，再打 `ttranslatev3`）
//
// 共性（与本地/在线 LLM 通道的差异，必须明确）：
// - **非流式**：整句一次性返回，不走 SSE。未实现 translateStreaming，
//   走协议默认实现（一次性回调完整译文），字幕按整句上屏。
// - **无配置项**：没有端点/Key/模型/提示词，设置页零输入框。
// - **公共端点有速率限制**：429 / 会话失效属常态瞬时错误，本通道自带
//   退避重试与会话刷新（见 FreeWebTransport.perform）；连续失败仍由
//   TranslationManager 按通用规则降级。
// - **不消费 Prompt / 上下文**：这些端点不接受 system prompt，翻译风格
//   预设（TranslationPromptPreset）对本通道无效——设置页据此隐藏提示词区。
//
// 实测结论（2026-09-11，本机直连）：
// - Google 两条通道**同域**（translate.googleapis.com）但拦截策略不同：
//   v2（dict-chrome-ex）正常返回；v1（gtx）返回 Google 的 "Sorry" 反滥用
//   HTML 页（IP/风控级拦截，浏览器 UA 无效）。因此 v1 通道在被拦截时会
//   **自动回落一次 v2**，并在日志中记录；设置页文案已注明。
// - `edge.microsoft.com/translate/auth`（Edge 免 key 领 JWT 的旧路径）
//   **现已 404 下线**，故微软通道改走 Bing 网页会话路径。该路径返回体
//   与 Edge 路径同构（`translations[0].text` + `detectedLanguage`），
//   解析器可共用。
// - Bing `ttranslatev3` **不接受多段**（重复 `text` 只翻第一段），
//   因此微软通道与 Google 一样逐行请求 + 有界并发保序。

/// 公共免 key 翻译通道。
enum FreeWebTranslationChannel: String, Sendable, CaseIterable {
    case googleV1
    case googleV2
    case microsoft

    var label: String {
        switch self {
        case .googleV1: return "Google 翻译 v1"
        case .googleV2: return "Google 翻译 v2"
        case .microsoft: return "微软翻译"
        }
    }

    var providerKind: TranslationProviderKind {
        switch self {
        case .googleV1: return .googleV1
        case .googleV2: return .googleV2
        case .microsoft: return .microsoft
        }
    }

    /// 设置页「翻译方式」行下方的说明。
    var detail: String {
        switch self {
        case .googleV1:
            return "translate-pa 网关（Google 网站翻译控件同源）· 无需 Key"
        case .googleV2:
            return "translate_a/t（Chrome 词典扩展同源）· 无需 Key"
        case .microsoft:
            return "Bing 网页翻译同源 · 无需 Key"
        }
    }
}

// MARK: - Provider

/// 公共免 key 翻译 Provider（按通道参数化）。
struct FreeWebTranslationProvider: TranslationProvider {
    let channel: FreeWebTranslationChannel

    var kind: TranslationProviderKind { channel.providerKind }

    /// 单通道并发上限（公共端点，保守取 4）。
    private static let maxConcurrency = 4
    /// 批次之间的最小间隔：免费端点连发易触发限流。
    private static let batchSpacing = Duration.milliseconds(120)

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        // 与 LLM 通道一致：NFKC 归一化（全角→半角）+ trim。
        let texts = request.texts.map { TranslationService.normalizeForTranslation($0) }
        guard !texts.isEmpty else {
            return TranslationResult(texts: [], targetLanguage: request.targetLanguage)
        }
        let source = (request.sourceLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = self.channel
        let target = request.targetLanguage

        var output = Array(repeating: "", count: texts.count)
        var detected: String?
        var lastError: Error?
        var failedLines = 0
        var translatedLines = 0
        var offset = 0

        while offset < texts.count {
            let end = min(offset + Self.maxConcurrency, texts.count)
            let slice = Array(texts[offset..<end])

            // 非抛错任务组：**单行失败不得牵连同批兄弟行**。
            // 批量场景（整段转录 20 句一批）里一行被限流/超时，若按抛错
            // 语义处理会让整批 20 句全丢；失败行退化为空串占位，与 LLM
            // 通道"缺失行补空"的语义一致。是否整体失败由下面的
            // 全失败判据决定。
            let results = await withTaskGroup(
                of: (Int, Result<(text: String, detected: String?), Error>).self
            ) { group -> [Result<(text: String, detected: String?), Error>] in
                for (index, line) in slice.enumerated() {
                    group.addTask {
                        do {
                            let value = try await FreeWebTransport.line(
                                line, channel: channel, source: source, target: target)
                            return (index, .success(value))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var local: [Result<(text: String, detected: String?), Error>] =
                    Array(repeating: .failure(TranslationError.parseError), count: slice.count)
                for await (index, result) in group { local[index] = result }
                return local
            }

            for (index, result) in results.enumerated() {
                switch result {
                case .success(let value):
                    output[offset + index] = value.text
                    translatedLines += 1
                    if detected == nil { detected = value.detected }
                case .failure(let error):
                    // 取消必须原样上抛：被当成"单行失败"吞掉会让停止/退出
                    // 无法中断在途翻译。
                    if error is CancellationError { throw error }
                    failedLines += 1
                    lastError = error
                    AppLogger.shared.log(.translation,
                        "\(channel.label) 第 \(offset + index + 1) 行失败，跳过："
                        + error.localizedDescription)
                }
            }

            try Task.checkCancellation()
            offset = end
            if offset < texts.count {
                try await Task.sleep(for: Self.batchSpacing)
            }
        }

        // 一行都没成功 = 通道整体不可用（被拦截/断网/全部限流）：抛出错误，
        // 让上层按既有规则处理（三连败降级、错误提示）。部分成功则保留
        // 已得译文，不因个别行失败丢弃整段结果。
        if translatedLines == 0, let lastError {
            throw lastError
        }
        if failedLines > 0 {
            AppLogger.shared.log(.translation,
                "\(channel.label) 部分行失败：成功 \(translatedLines) / 失败 \(failedLines)")
        }

        return TranslationResult(texts: output,
                                 sourceLanguage: detected,
                                 targetLanguage: request.targetLanguage)
    }

    // MARK: TranslationProvider

    func testConnection() async -> TranslationConnectionStatus {
        let stored = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
        let target = stored.isEmpty ? "en" : stored
        do {
            let result = try await translate(
                TranslationRequest(text: "Hello, world.", targetLanguage: target))
            let sample = result.texts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sample.isEmpty else { return .failed("空响应") }
            return .connected(model: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func status() async -> TranslationProviderStatus {
        .ready(description: "\(channel.label)（公共端点 · 免 Key）")
    }
}

// MARK: - 传输层

/// 公共端点的 HTTP 传输（Google 两条 + 微软一条）。
enum FreeWebTransport {
    /// 公共端点常规 UA（默认 URLSession UA 可能被拒）。
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// 严格百分号编码（RFC 3986 unreserved 之外一律编码）。
    ///
    /// 为什么不用 `URLComponents.queryItems` 自带的编码：它把 `+` 原样留在
    /// query 里（实测 `q=C++%201+1`）。而 Google `translate_a/*` 与 Bing
    /// `ttranslatev3`（后者本身就是 application/x-www-form-urlencoded）都按
    /// 表单语义把 `+` 解成**空格** —— 原文里的 `+` 被吃掉：
    /// "C++ 教程" → "C  教程"。空格 URLComponents 会正确编成 %20，
    /// 所以需要补的就是 `+` 之类「编码器认为合法、接收方却另有解释」的字符。
    static func encodeComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 按严格编码拼 query / form body（name 与 value 都编码）。
    static func encodeQuery(_ items: [(String, String)]) -> String {
        items.map { "\(encodeComponent($0.0))=\(encodeComponent($0.1))" }
            .joined(separator: "&")
    }

    /// 单行翻译分发。
    static func line(_ text: String,
                     channel: FreeWebTranslationChannel,
                     source: String,
                     target: String) async throws -> (text: String, detected: String?) {
        switch channel {
        case .googleV1:
            do {
                return try await googleLine(text, channel: .googleV1, source: source, target: target)
            } catch let error as TranslationError {
                // v1 被风控拦截（同域的 v2 通道仍可用）时自动回落一次，
                // 避免用户选到 v1 后直接不可用；日志留痕，不静默。
                guard case .endpointBlocked = error else { throw error }
                AppLogger.shared.log(.translation, "Google v1 被拦截，自动回落 v2 通道")
                return try await googleLine(text, channel: .googleV2, source: source, target: target)
            }
        case .googleV2:
            return try await googleLine(text, channel: .googleV2, source: source, target: target)
        case .microsoft:
            return try await microsoftLine(text, source: source, target: target)
        }
    }

    // MARK: Google

    /// Google 单行翻译（分片后逐片请求，最后拼接）。
    ///
    /// 端点选择（2026-09 实测）：
    /// - **googleV1 = translate-pa 网关**（Google 自家网站翻译控件 te_lib 的
    ///   后端）。旧的 `translate_a/*` 免 key 端点已被 Google 反滥用墙收紧：
    ///   实测 429 / 302→google.com/sorry / 403，且**换出口 IP 无效**
    ///   （日本、香港、台湾三个节点全 429），属服务端策略而非 IP 声誉。
    ///   translate-pa 走正规 CORS 网关并提供公开的 te_lib key，实测 200。
    /// - **googleV2 = 旧 translate_a/t**，保留给该端点仍可用的网络环境。
    /// 端点选择（2026-09 实测）：
    /// - **googleV1 = translate-pa 网关**（Google 自家网站翻译控件 te_lib 的
    ///   后端）。旧的 `translate_a/*` 免 key 端点已被 Google 反滥用墙收紧：
    ///   实测 429 / 302→google.com/sorry / 403，且**换出口 IP 无效**
    ///   （日本、香港、台湾三个节点全 429），属服务端策略而非 IP 声誉。
    /// - **googleV2 = 旧 translate_a/t**（Chrome 词典扩展同源）。
    ///
    /// **两条都做双向回落**：端点级封禁是 Google 单方面、随时可能变的策略，
    /// 实测当前 v2 已 100% 失败（429）而 v1 可用；反过来在某些网络/时段
    /// 也可能只有 v2 通。任一条失败且属"网关可用性故障"时改走另一条，
    /// 让用户选哪条都能用，而不是选到死的那条就整块失效。
    /// 请求本身有问题（400 invalid argument / 解析失败）时不回落——
    /// 换端点同样失败，只会白费一次往返还掩盖真实错误。
    static func googleLine(_ text: String,
                           channel: FreeWebTranslationChannel,
                           source: String,
                           target: String) async throws -> (text: String, detected: String?) {
        switch channel {
        case .googleV1:
            do {
                return try await googleTranslatePA(text, source: source, target: target)
            } catch let error as TranslationError where error.isGatewayAvailabilityFailure {
                AppLogger.shared.log(.translation,
                    "Google translate-pa 不可用，回落 translate_a：\(error.localizedDescription)")
                return try await googleLegacy(text, channel: .googleV2,
                                              source: source, target: target)
            }
        case .googleV2:
            do {
                return try await googleLegacy(text, channel: .googleV2,
                                              source: source, target: target)
            } catch let error as TranslationError where error.isGatewayAvailabilityFailure {
                AppLogger.shared.log(.translation,
                    "Google translate_a 不可用，回落 translate-pa：\(error.localizedDescription)")
                return try await googleTranslatePA(text, source: source, target: target)
            }
        case .microsoft:
            throw TranslationError.invalidEndpoint
        }
    }

    // MARK: Google · translate-pa 网关（googleV1 主通道）

    /// Google 网站翻译控件（te_lib）的公开 API key。
    ///
    /// 这**不是**用户密钥：它就是 Google 自己的 te_lib 加载器内联在网页里的
    /// key，语义等同于旧 `client=gtx` 参数（共享的免费后端）。测试
    /// md-translator / nightcord 等开源项目均使用同一个值。
    static let translatePAKey = "AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520"
    static let translatePAURL = "https://translate-pa.googleapis.com/v1/translateHtml"

    /// 经 translate-pa 翻译文本（逐片请求；该网关单请求可带数组，见下方注释）。
    static func googleTranslatePA(_ text: String,
                                  source: String,
                                  target: String) async throws -> (text: String, detected: String?) {
        let pieces = chunk(text)
        var translated: [String] = []
        var detected: String?

        for piece in pieces {
            let outcome = try await translatePAOnce([piece], source: source, target: target)
            if detected == nil { detected = outcome.detected }
            translated.append(outcome.texts.first ?? "")
        }
        // 分片场景以空格拼接（仅在超长段落触发）。
        return (translated.joined(separator: " ").trimmingCharacters(in: .whitespaces), detected)
    }

    /// 单次 translate-pa 请求（支持一次传多段，返回平行数组）。
    ///
    /// 协议（实测 2026-09，全部行为已逐项验证）：
    /// - `POST https://translate-pa.googleapis.com/v1/translateHtml`
    /// - `Content-Type: application/json+protobuf`，`X-Goog-API-Key: <te_lib key>`
    /// - body：`[[[文本…], 源语言, 目标语言], "te_lib"]`
    ///   （`[[文本,…], "te_lib"]` 这种缺语言码的形状会被 400 拒绝）
    /// - 响应：`[[译文…], [检测语言…]]`；显式源语言时第二项可能缺失
    /// - **响应是 HTML 转义的**：`<` → `&lt;`、`&` → `&amp;`
    ///   （实测输入 `a < b & c` 返回 `a &lt; b &amp; c`），必须反转义后再用
    /// - **空串元素会 400**（`Request contains an invalid argument`），
    ///   所以调用前要剔除空串并按位置回填
    static func translatePAOnce(_ texts: [String],
                                source: String,
                                target: String) async throws -> (texts: [String], detected: String?) {
        // 空串元素会被网关拒绝：只发非空项，结果按位置回填（保序）。
        var sentIndices: [Int] = []
        var payload: [String] = []
        for (index, item) in texts.enumerated() where !item.isEmpty {
            sentIndices.append(index)
            payload.append(item)
        }
        guard !payload.isEmpty else {
            return (Array(repeating: "", count: texts.count), nil)
        }

        guard let url = URL(string: translatePAURL) else {
            throw TranslationError.invalidEndpoint
        }
        let sourceCode = FreeWebParsing.googleLanguageCode(source.isEmpty ? "auto" : source)
        let targetCode = FreeWebParsing.googleLanguageCode(target)
        let body: [Any] = [[payload, sourceCode, targetCode], "te_lib"]
        guard JSONSerialization.isValidJSONObject(body),
              let encoded = try? JSONSerialization.data(withJSONObject: body) else {
            throw TranslationError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(translatePAKey, forHTTPHeaderField: "X-Goog-API-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.httpBody = encoded

        let data = try await perform(request, context: "Google 翻译")
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            if let block = FreeWebTransport.abuseBlockDescription(status: 200, data: data) {
                throw TranslationError.endpointBlocked("Google 翻译：\(block)")
            }
            throw TranslationError.endpointBlocked(
                "Google 翻译返回非 JSON：\(Self.readablePreview(data, limit: 120))")
        }
        return try FreeWebParsing.translatePAResult(from: json, texts: texts,
                                                    sentIndices: sentIndices)
    }

    /// 旧 `translate_a` 端点（googleV2 主通道；googleV1 的兜底）。
    static func googleLegacy(_ text: String,
                             channel: FreeWebTranslationChannel,
                             source: String,
                             target: String) async throws -> (text: String, detected: String?) {
        let pieces = chunk(text)
        var translated: [String] = []
        var detected: String?

        for piece in pieces {
            guard let url = googleURL(piece, channel: channel, source: source, target: target) else {
                throw TranslationError.invalidEndpoint
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20

            let data = try await perform(request, context: channel.label)
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                // Google 反滥用时返回 HTML 而非 JSON（HTTP 可能是 200 但体是拦截页）。
                if let block = FreeWebTransport.abuseBlockDescription(
                    status: 200, data: data) {
                    throw TranslationError.endpointBlocked("\(channel.label)：\(block)")
                }
                let preview = Self.readablePreview(data, limit: 120)
                throw TranslationError.endpointBlocked(
                    "\(channel.label) 返回非 JSON（疑似风控拦截/需要代理）：\(preview)")
            }
            guard let text = FreeWebParsing.googleTranslation(from: json) else {
                throw TranslationError.parseError
            }
            if detected == nil { detected = FreeWebParsing.googleDetectedLanguage(from: json) }
            translated.append(text)
        }
        // 分片场景以空格拼接（仅在超长段落触发）。
        return (translated.joined(separator: " ").trimmingCharacters(in: .whitespaces), detected)
    }

    /// Google GET URL（query 编码交给 URLComponents，`+`/`&` 不会破坏参数）。
    static func googleURL(_ text: String,
                          channel: FreeWebTranslationChannel,
                          source: String,
                          target: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "translate.googleapis.com"
        // Google 语言码映射：tl/sl 必须是 Google 方言（zh-CN/zh-TW），
        // 不接受 BCP-47 的 zh-Hans/zh-Hant（此前映射函数定义了却从未调用，
        // 选简体/繁体中文目标时把非法码发给 Google → 结果异常）。
        let googleSource = FreeWebParsing.googleLanguageCode(source.isEmpty ? "auto" : source)
        let googleTarget = FreeWebParsing.googleLanguageCode(target)
        // 用严格编码拼 query（URLComponents 不编 `+`，会让 "C++" 变成 "C  "）。
        let pairs: [(String, String)]
        switch channel {
        case .googleV1:
            components.path = "/translate_a/single"
            pairs = [
                ("client", "gtx"),
                ("sl", googleSource),
                ("tl", googleTarget),
                ("dt", "t"),
                ("q", text),
            ]
        case .googleV2:
            components.path = "/translate_a/t"
            pairs = [
                ("client", "dict-chrome-ex"),
                ("sl", googleSource),
                ("tl", googleTarget),
                ("q", text),
            ]
        case .microsoft:
            return nil
        }
        components.percentEncodedQuery = Self.encodeQuery(pairs)
        return components.url
    }

    // MARK: 微软（Bing 网页会话）

    /// Bing 单行翻译（重复 text 只翻第一段，故逐行请求）。
    static func microsoftLine(_ text: String,
                              source: String,
                              target: String) async throws -> (text: String, detected: String?) {
        let pieces = chunk(text, limit: 900)
        var translated: [String] = []
        var detected: String?

        for piece in pieces {
            let outcome = try await microsoftOnce(piece, source: source, target: target, refresh: false)
            if detected == nil { detected = outcome.detected }
            translated.append(outcome.text)
        }
        return (translated.joined(separator: " ").trimmingCharacters(in: .whitespaces), detected)
    }

    /// 单次 Bing 请求；会话失效（205）时刷新会话重试一次。
    private static func microsoftOnce(_ text: String,
                                      source: String,
                                      target: String,
                                      refresh: Bool) async throws -> (text: String, detected: String?) {
        let session = try await BingSessionProvider.current(forceRefresh: refresh)
        guard let url = bingURL(session: session) else {
            throw TranslationError.invalidEndpoint
        }

        // 表单体（重复键用多次 append，不能用字典）。
        // 严格编码：本请求的 Content-Type 就是 application/x-www-form-urlencoded，
        // 服务端会把裸 `+` 解成空格（URLComponents 不编 `+`）。
        let formBody = FreeWebTransport.encodeQuery([
            ("fromLang", source.isEmpty ? "auto-detect" : source),
            ("text", text),
            ("to", FreeWebParsing.microsoftLanguageCode(target)),
            ("token", session.token),
            ("key", session.key),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bing.com/translator", forHTTPHeaderField: "Referer")
        request.httpBody = formBody.data(using: .utf8)
        request.timeoutInterval = 25

        var httpStatus = 0
        let data = try await perform(request, context: "微软翻译") { status in
            httpStatus = status
        }
        let json = try? JSONSerialization.jsonObject(with: data)

        // Bing 的业务错误以 HTTP 200 + {"statusCode":…} 返回，需先于结果解析。
        if let json, let error = FreeWebParsing.microsoftError(from: json) {
            if case .authFailed = error, !refresh {
                BingSessionProvider.invalidate()
                return try await microsoftOnce(text, source: source, target: target, refresh: true)
            }
            throw error
        }
        guard let json else {
            let preview = FreeWebTransport.readablePreview(data, limit: 120)
            throw TranslationError.endpointBlocked(
                "微软翻译返回非 JSON（HTTP \(httpStatus)）：\(preview)")
        }
        guard let result = FreeWebParsing.microsoftResult(from: json, count: 1) else {
            throw TranslationError.parseError
        }
        return (result.texts.first ?? "", result.detected)
    }

    /// Bing 翻译端点 URL（IG/IID 来自会话页）。
    static func bingURL(session: BingTranslationSession) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.bing.com"
        components.path = "/ttranslatev3"
        // 同 Google：走严格编码（IG/IID 是十六进制不含 `+`，但保持一致，
        // 避免后续新增参数时再踩同一个坑）。
        components.percentEncodedQuery = FreeWebTransport.encodeQuery([
            ("isVertical", "1"),
            ("IG", session.ig),
            ("IID", session.iid),
        ])
        return components.url
    }

    // MARK: 重试

    /// 公共端点重试：429 / 5xx / 传输错误退避重试，最多 2 次。
    /// 免费端点限流是常态，不能像付费 API 那样一撞就降级到「仅识别模式」。
    /// `onStatus` 回传最近一次 HTTP 状态码（错误体解析需要）。
    static func perform(_ request: URLRequest,
                        context: String,
                        onStatus: ((Int) -> Void)? = nil) async throws -> Data {
        let backoffs: [Duration] = [.milliseconds(600), .milliseconds(1500)]
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await rawPerform(request, context: context, onStatus: onStatus)
            } catch let error as TranslationError {
                guard error.isRetryableOnFreeChannel, attempt < backoffs.count else { throw error }
                AppLogger.shared.log(.translation,
                    "\(context) 失败（第 \(attempt + 1) 次），退避重试：\(error.localizedDescription)")
                try await Task.sleep(for: backoffs[attempt])
                attempt += 1
            }
        }
    }

    private static func rawPerform(_ request: URLRequest,
                                   context: String,
                                   onStatus: ((Int) -> Void)?) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslationError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.transport("Invalid response")
        }
        onStatus?(http.statusCode)
        if (200...299).contains(http.statusCode), !data.isEmpty {
            return data
        }
        // 反滥用拦截页识别：Google 对可疑出口 IP 返回 429 或 302→
        // `google.com/sorry`，响应体是 HTML（不是 JSON）。把它当普通
        // "429 限流" 处理会有两个问题：① 错误文案把整段 HTML 糊到用户脸上
        //（实测截图如此）；② `.rateLimited` 属于"可重试的瞬时错误"，
        // 而 IP 级拦截重试毫无意义，白白退避等待。
        if let block = Self.abuseBlockDescription(status: http.statusCode, data: data) {
            throw TranslationError.endpointBlocked("\(context)：\(block)")
        }
        let preview = Self.readablePreview(data)
        let detail = "\(context) HTTP \(http.statusCode)"
            + (preview.isEmpty ? "" : "：\(preview)")
        switch http.statusCode {
        case 401, 403: throw TranslationError.authFailed(detail)
        case 429: throw TranslationError.rateLimited(detail)
        case 500...599: throw TranslationError.serverError(http.statusCode, detail)
        default: throw TranslationError.apiFailed(detail)
        }
    }

    /// 识别反滥用拦截页；命中返回**给用户看的一句话**，未命中返回 nil。
    ///
    /// 判据（满足其一）：
    /// - 响应体像 HTML（`<html` / `<!DOCTYPE`）——正常接口只返回 JSON；
    /// - 体里含 Google 的 `automated queries` / `google.com/sorry` 字样。
    /// 只对 429 / 403 / 302 等失败码调用（成功路径在上面已返回）。
    static func abuseBlockDescription(status: Int, data: Data) -> String? {
        let body = String(data: data, encoding: .utf8) ?? ""
        let head = body.prefix(2048).lowercased()
        let looksLikeHTML = head.contains("<html") || head.contains("<!doctype")
        let mentionsAbuse = head.contains("automated queries")
            || head.contains("google.com/sorry")
            || head.contains("/sorry/index")
        guard looksLikeHTML || mentionsAbuse else { return nil }

        if mentionsAbuse || head.contains("translate.google") {
            return "出口 IP 被 Google 反滥用拦截（HTTP \(status)）。"
                + "这与请求内容无关，机房/云主机网段常被整段拒绝。"
                + "可改用「微软翻译」通道，或在上方「代理」中配置代理换出口。"
        }
        return "端点返回网页而非数据（HTTP \(status)），可能被风控拦截或需要代理。"
    }

    /// 把响应体转成**适合展示的一小段文本**：HTML 去掉标签与多余空白，
    /// 避免错误文案里出现 `<!DOCTYPE html PUBLIC "-//W3C//DTD ...` 这种噪声。
    static func readablePreview(_ data: Data, limit: Int = 160) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "" }
        var text = raw
        if text.prefix(2048).lowercased().contains("<html")
            || text.prefix(2048).lowercased().contains("<!doctype") {
            // 粗剥标签 → 折叠空白（够用即可，不为展示引入 HTML 解析器）。
            text = text.replacingOccurrences(
                of: "<[^>]+>", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression)
        }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// 超长文本分片（GET + query 有长度上限；Bing 单请求 1000 字符上限）：
    /// `limit` 是**硬上界**——到边界即切，无边界也最多撑到 limit 强制切。
    /// （此前实现允许累积到 2×limit，Bing 传 900 时单片可达 1800 字符，
    /// 超过其 1000 上限导致长句被拒。）
    /// 实时单句远低于阈值，仅长段落触发。
    static func chunk(_ text: String, limit: Int = 1500) -> [String] {
        guard text.count > limit else { return [text] }
        let boundaries = Set("，。！？；、,.!?; \n\t")
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            let atBoundary = character.isWhitespace || boundaries.contains(character)
            if current.count >= limit {
                chunks.append(current)
                current = ""
            } else if atBoundary, current.count >= limit / 2 {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

// MARK: - Bing 网页翻译会话（微软免 key 通道的鉴权来源）

/// 一次 Bing 翻译会话的页面参数。
struct BingTranslationSession: Sendable, Equatable {
    /// 页面注入的请求标识。
    let ig: String
    /// 页面实例 id（`translator.NNNN`）。
    let iid: String
    /// 防滥用 key（`params_AbusePreventionHelper` 首项）。
    let key: String
    /// 防滥用 token（同数组第二项）。
    let token: String
    /// 缓存到期时间。
    let expiresAt: Date
}

/// Bing 会话的抓取与缓存。
///
/// 免 key 原理：Bing 翻译网页把 `IG` / `params_AbusePreventionHelper`
/// （key + token + 有效期）内联在 HTML 里，`ttranslatev3` 只校验这些东西，
/// 因此抓一次页面即可翻译，无需订阅 Key。
enum BingSessionProvider {
    static let pageURL = "https://www.bing.com/translator"
    private static let store = SessionStore()

    /// single-flight：并发首个请求（批量翻译最多 4 路并发）共享同一次抓取，
    /// 避免缓存为空时重复 GET 会话页（浪费请求且易触发风控限流）。
    private static let flightLock = NSLock()
    private static var inFlight: Task<BingTranslationSession, Error>?

    /// 在非 async 上下文获取（或创建）共享抓取任务。
    /// 锁操作放在同步函数里，避免 NSLock 在 async 上下文中的告警/未定义行为。
    private static func sharedScrapeTask() -> (task: Task<BingTranslationSession, Error>, owns: Bool) {
        flightLock.lock()
        defer { flightLock.unlock() }
        if let existing = inFlight { return (existing, false) }
        let task = Task<BingTranslationSession, Error> {
            let fresh = try await scrape()
            store.store(fresh)
            return fresh
        }
        inFlight = task
        return (task, true)
    }

    private static func clearFlight() {
        flightLock.lock()
        inFlight = nil
        flightLock.unlock()
    }

    /// 取有效会话（缓存命中直接返回；失效则重新抓取页面）。
    static func current(forceRefresh: Bool = false) async throws -> BingTranslationSession {
        if !forceRefresh, let cached = store.valid() { return cached }
        let (task, owns) = sharedScrapeTask()
        do {
            let session = try await task.value
            if owns { clearFlight() }
            return session
        } catch {
            if owns { clearFlight() }
            throw error
        }
    }

    /// 作废缓存（205 后调用，下次重新抓取）。
    static func invalidate() {
        store.clear()
    }

    static func scrape() async throws -> BingTranslationSession {
        guard let url = URL(string: pageURL) else { throw TranslationError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(FreeWebTransport.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let data = try await FreeWebTransport.perform(request, context: "微软翻译会话")
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw TranslationError.parseError
        }
        return try parse(html)
    }

    /// 从页面 HTML 解析会话参数（纯逻辑，单测覆盖）。
    static func parse(_ html: String) throws -> BingTranslationSession {
        guard let ig = capture(#"IG:"([^"]+)""#, in: html, group: 1) else {
            throw TranslationError.endpointBlocked("微软翻译会话页缺少 IG（页面结构可能已变更）")
        }
        // 页面含多个 data-iid（translator.5025 / .5026 / .5028…），取最后一个。
        guard let iid = lastCapture(#"data-iid="(translator\.\d+)""#, in: html) else {
            throw TranslationError.endpointBlocked("微软翻译会话页缺少 IID（页面结构可能已变更）")
        }
        guard let helper = parseAbuseHelper(html) else {
            throw TranslationError.endpointBlocked("微软翻译会话页缺少防滥用参数（页面结构可能已变更）")
        }
        // 有效期为页面给出的毫秒数；按 85% 折算并在 1 小时内封顶，避免边界失效。
        let lifetime = min(max(helper.intervalMs / 1000.0, 60), 3600)
        return BingTranslationSession(
            ig: ig,
            iid: iid,
            key: helper.key,
            token: helper.token,
            expiresAt: Date().addingTimeInterval(lifetime * 0.85))
    }

    /// 解析 `params_AbusePreventionHelper = [key, "token", intervalMs]`。
    static func parseAbuseHelper(_ html: String) -> (key: String, token: String, intervalMs: Double)? {
        let pattern = #"params_AbusePreventionHelper\s*=\s*\[\s*(\d+)\s*,\s*"([^"]+)"\s*,\s*(\d+)\s*\]"#
        guard let groups = matchGroups(pattern, in: html, last: false), groups.count >= 4 else {
            return nil
        }
        return (key: groups[1], token: groups[2], intervalMs: Double(groups[3]) ?? 3_600_000)
    }

    /// 返回首个匹配的指定捕获组（1-based）。无匹配返回 nil。
    static func capture(_ pattern: String, in text: String, group: Int) -> String? {
        guard let groups = matchGroups(pattern, in: text, last: false), groups.count > group else {
            return nil
        }
        return groups[group]
    }

    /// 返回最后一个匹配的第一个捕获组（页面内多实例取末尾）。
    static func lastCapture(_ pattern: String, in text: String) -> String? {
        guard let groups = matchGroups(pattern, in: text, last: true), groups.count > 1 else {
            return nil
        }
        return groups[1]
    }

    /// 正则匹配 → 捕获组数组（索引 0 为整段匹配）。
    private static func matchGroups(_ pattern: String,
                                    in text: String,
                                    last: Bool) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard let match = last ? matches.last : matches.first else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let captured = Range(match.range(at: index), in: text) else { return "" }
            return String(text[captured])
        }
    }

    /// 线程安全会话缓存（Provider 为值类型，状态必须落在共享存储上）。
    private final class SessionStore: @unchecked Sendable {
        private let lock = NSLock()
        private var session: BingTranslationSession?

        /// 过期前 30 秒即视为无效（避免边界上带着将死会话发请求）。
        func valid() -> BingTranslationSession? {
            lock.lock(); defer { lock.unlock() }
            guard let session, session.expiresAt > Date().addingTimeInterval(30) else { return nil }
            return session
        }

        func store(_ newSession: BingTranslationSession) {
            lock.lock(); defer { lock.unlock() }
            session = newSession
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            session = nil
        }
    }
}

// MARK: - 响应解析与语言码映射（纯逻辑，单测覆盖）

enum FreeWebParsing {
    // MARK: 译文清洗

    /// 剔除译文里的**不可见格式字符**。
    ///
    /// Google 会在数字/单位边界插入 U+200B（零宽空格）做断行提示——实测
    /// "同比增长 12.5%，" → `12.5%\u{200B}\u{200B}year-over-year`。
    /// 这些字符：
    /// - 肉眼不可见，但 `Character("\u{200B}").isWhitespace == false`，
    ///   而 `CharacterSet.whitespaces` **包含**它 → `trimmingCharacters`
    ///   清不掉（trim 只去首尾，且这里在中间）；
    /// - 占 `String.count` 一个字符位 → 字幕按字数换行/断句的宽度计算偏大；
    /// - 随复制、SRT 导出、历史 JSON 一起落盘 → 用户粘贴到别处带进隐形字符，
    ///   搜索 "12.5% year" 匹配失败。
    /// 同理清掉其余常用零宽/双向控制符（来自网页抓取通道的常见噪声）。
    static func sanitizeTranslation(_ text: String) -> String {
        guard !text.unicodeScalars.isEmpty else { return text }
        var cleaned = String.UnicodeScalarView()
        cleaned.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F,   // 零宽空格/连接符/不连字符 + LRM/RLM
                 0x202A...0x202E,   // 双向嵌入/覆盖控制符
                 0x2060...0x2064,   // word joiner / 不可见运算符
                 0xFEFF:            // BOM / 零宽不换行空格
                continue
            default:
                cleaned.append(scalar)
            }
        }
        return String(cleaned)
    }

    // MARK: Google · translate-pa

    /// 解析 translate-pa 响应：`[[译文…], [检测语言…]]`。
    ///
    /// 要点：
    /// - 译文数组与**发送的**文本数组平行；调用方已剔除空串，这里按
    ///   `sentIndices` 回填到原始下标（保持与入参一一对齐——错位会把
    ///   译文填到别的句子上）。
    /// - 译文是 HTML 转义的（`&lt;` / `&amp;` / `&#39;`），必须反转义；
    ///   否则用户会看到 `C++ &amp; ...` 这种字面实体。
    /// - 检测语言数组可能缺失（显式源语言时实测不出），此时不报错。
    static func translatePAResult(from json: Any,
                                  texts: [String],
                                  sentIndices: [Int]) throws -> (texts: [String], detected: String?) {
        guard let root = json as? [Any] else { throw TranslationError.parseError }
        // 错误体：`[code, "message", …]`（首元素为数字）。
        if let code = root.first as? Int {
            let message = (root.count > 1 ? root[1] as? String : nil) ?? ""
            throw TranslationError.apiFailed("Google 翻译错误（\(code)）：\(message)")
        }
        guard let rawTranslations = root.first as? [Any] else { throw TranslationError.parseError }

        var out = Array(repeating: "", count: texts.count)
        for (offset, element) in rawTranslations.enumerated() {
            guard offset < sentIndices.count else { break }
            guard let raw = element as? String else { continue }
            out[sentIndices[offset]] = sanitizeTranslation(unescapeHTMLEntities(raw))
        }
        var detected: String?
        if root.count > 1, let langs = root[1] as? [Any],
           let first = langs.first as? String, !first.isEmpty {
            detected = first
        }
        return (out, detected)
    }

    /// HTML 实体反转义。
    ///
    /// translate-pa 把译文按 HTML 语义输出：`<` → `&lt;`、`&` → `&amp;`
    /// （实测输入 `a < b & c` 返回 `a &lt; b &amp; c`）。只处理该网关实际
    /// 会产出的实体，不做通用 HTML 解析。
    /// 逐段扫描（而非链式 replacingOccurrences）以避免二次解码：
    /// `&amp;lt;` 应成为字面 `&lt;`，链式替换会把它错误地解成 `<`。
    static func unescapeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "&amp;": "&",     // 必须与扫描顺序配合：左→右扫过即跳过，不会二次解码
            "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": "\u{00A0}",
        ]
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let amp = text[index...].firstIndex(of: "&") else {
                output += text[index...]
                break
            }
            output += text[index..<amp]
            // 实体不会太长；限长避免把正文里的 "&" 一路吞到远处分号。
            let limit = text.index(amp, offsetBy: 12, limitedBy: text.endIndex)
                ?? text.endIndex
            if let semi = text[amp..<limit].firstIndex(of: ";") {
                let entity = String(text[amp...semi])
                if let decoded = decodeEntity(entity, named: named) {
                    output += decoded
                    index = text.index(after: semi)
                    continue
                }
            }
            output += "&"
            index = text.index(after: amp)
        }
        return output
    }

    /// 单个实体的解码（命名 + 十进制 + 十六进制）。
    private static func decodeEntity(_ entity: String,
                                     named: [String: String]) -> String? {
        if let value = named[entity] { return value }
        guard entity.hasPrefix("&#"), entity.hasSuffix(";") else { return nil }
        let body = String(entity.dropFirst(2).dropLast())
        let scalarValue: UInt32?
        if body.hasPrefix("x") || body.hasPrefix("X") {
            scalarValue = UInt32(body.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(body, radix: 10)
        }
        guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    // MARK: Google · translate_a（旧端点）

    /// 抽取 Google 译文。宽容多代接口形状（不做结构断言，逐层下钻）：
    /// - v1: `[[["译文","原文",null,null,10]],null,"en",...]`
    /// - v2（sl=auto）: `[["译文","en"]]`；多段 `[["译文一","en"],["译文二","en"]]`
    /// - v2（sl=**显式源语言**）: `["译文"]` —— 扁平字符串数组（实测；
    ///   服务端在已知源语言时省掉语言码那一项）
    /// - te=1 变体: `{"sentences":[{"trans":"译文","orig":"原文"}]}`
    static func googleTranslation(from json: Any) -> String? {
        if let dictionary = json as? [String: Any],
           let sentences = dictionary["sentences"] as? [[String: Any]] {
            let joined = sentences.compactMap { $0["trans"] as? String }.joined()
            return joined.isEmpty ? nil : sanitizeTranslation(joined)
        }
        // 扁平字符串数组：v2 在显式源语言下的**顶层**形状。
        // 必须先于 googleSegments 判断——后者要求每段至少两元，
        // 对这种形状返回 nil → 译文被丢成 parseError。
        if let flat = googleFlatStrings(from: json) { return flat }
        guard let segments = googleSegments(from: json), !segments.isEmpty else { return nil }
        let joined = segments.joined()
        return joined.isEmpty ? nil : sanitizeTranslation(joined)
    }

    /// 顶层为「纯字符串数组」的响应（`["译文"]` / `["段一","段二"]`）。
    ///
    /// 需要两个排除条件才敢认，否则会把别的形状当成译文：
    /// - 任一元素不是字符串 → 不是（v1/v2 嵌套结构的首元素都是数组）；
    /// - 多个元素**且全部**是语言码形态 → 那是 `["en","zh-CN"]` 这类
    ///   语言码列表，不是译文（已有回归用例守着这个形状）。
    /// 单元素即使是 "en" 也照收：显式源语言下服务端就返回单元素数组，
    /// 而"翻译字面量 en"这种输入远不值得为它牺牲正常路径。
    private static func googleFlatStrings(from json: Any) -> String? {
        guard let array = json as? [Any], !array.isEmpty else { return nil }
        var pieces: [String] = []
        for element in array {
            guard let text = element as? String else { return nil }
            pieces.append(text)
        }
        if pieces.count > 1, pieces.allSatisfy(isLanguageCode) { return nil }
        let joined = pieces.joined()
        return joined.isEmpty ? nil : sanitizeTranslation(joined)
    }

    /// 下钻到「段列表」：段 = 首项为字符串且至少两元的数组
    /// （`[译文, 原文或源语言码, …]`）。先在同层找，找不到再逐层深入，
    /// 从而同时兼容 v1 的「多包一层」与 v2 的扁平结构。
    private static func googleSegments(from json: Any) -> [String]? {
        guard let array = json as? [Any] else { return nil }
        let direct = array.compactMap { element -> String? in
            guard let segment = element as? [Any],
                  segment.count >= 2,
                  let text = segment.first as? String,
                  !text.isEmpty else { return nil }
            return text
        }
        if !direct.isEmpty { return direct }
        for element in array {
            if let nested = googleSegments(from: element), !nested.isEmpty { return nested }
        }
        return nil
    }

    /// 抽取 Google 检测出的源语言。
    /// - v1：顶层数组第 3 项（`[<segments>, null, "en", …]`）；
    /// - v2：段的第二项即源语言码（实测 `[["你好世界。","en"]]`）。
    static func googleDetectedLanguage(from json: Any) -> String? {
        guard let array = json as? [Any] else { return nil }
        if array.count > 2, let code = array[2] as? String, isLanguageCode(code) {
            return code
        }
        for element in array {
            if let segment = element as? [Any], segment.count >= 2,
               let code = segment[1] as? String, isLanguageCode(code) {
                return code
            }
        }
        return nil
    }

    /// 语言码形状判据（`en` / `zh-CN` / `zh-Hans`），用于把「段第二项」
    /// 与「原文文本」区分开。
    static func isLanguageCode(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"^[A-Za-z]{2,3}(-[A-Za-z]{2,4})*$"#) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // MARK: 微软（Bing / Edge 同构）

    /// 微软业务错误体：`{"statusCode":205,"errorMessage":""}`。
    /// Bing 以 HTTP 200 返回业务错误，故必须先于结果解析检查。
    static func microsoftError(from json: Any) -> TranslationError? {
        guard let dictionary = json as? [String: Any],
              let code = dictionary["statusCode"] as? Int else { return nil }
        let message = dictionary["errorMessage"] as? String ?? ""
        switch code {
        case 205:
            return .authFailed("微软翻译会话已失效（205）\(message)")
        case 429:
            return .rateLimited("微软翻译限流（429）\(message)")
        case 500...599:
            return .serverError(code, message)
        case 400, 401, 403:
            return .authFailed("微软翻译拒绝请求（\(code)）\(message)")
        default:
            return .apiFailed("微软翻译错误（\(code)）\(message)")
        }
    }

    /// 微软响应解析：等长输出（缺项补空串，保证与输入行对齐）。
    /// 形状：`[{"translations":[{"text":"你好"}],"detectedLanguage":{"language":"en"}}]`
    ///
    /// 注意：`to` 为中文时 Bing 会在末尾追加**纯元数据元素**
    /// （`{"inputTransliteration":…,"script":"Latn"}`，无 `translations`），
    /// 这类元素必须整体跳过，否则会往结果里塞空串。
    static func microsoftResult(from json: Any, count: Int) -> (texts: [String], detected: String?)? {
        guard let array = json as? [Any] else { return nil }
        var texts: [String] = []
        var detected: String?
        for element in array {
            guard let item = element as? [String: Any] else { continue }
            guard let translations = item["translations"] as? [[String: Any]] else { continue }
            // 同一清洗口径（Bing 实测未插零宽字符，但通道失效降级/服务端改版
            // 都可能引入；清洗是幂等的，无用例成本）。
            texts.append(sanitizeTranslation(translations.first?["text"] as? String ?? ""))
            if detected == nil,
               let language = item["detectedLanguage"] as? [String: Any],
               let code = language["language"] as? String, !code.isEmpty {
                detected = code
            }
        }
        guard !texts.isEmpty else { return nil }
        if texts.count < count {
            texts += Array(repeating: "", count: count - texts.count)
        } else if texts.count > count {
            texts = Array(texts.prefix(count))
        }
        return (texts, detected)
    }

    // MARK: 语言码映射

    /// 应用内 locale id → Google 语言码。
    /// Google 用 `zh-CN`/`zh-TW`，不接受 BCP-47 的 `zh-Hans`/`zh-Hant`。
    static func googleLanguageCode(_ id: String) -> String {
        switch id {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "": return "en"
        default: return id
        }
    }

    /// 应用内 locale id → 微软语言码（Bing 与 BCP-47 一致，仅缺省回退）。
    static func microsoftLanguageCode(_ id: String) -> String {
        id.isEmpty ? "en" : id
    }
}
