import Foundation

#if DEBUG

// MARK: - 端到端评测工作台（ASRBench）
//
// 用法：
//   SonicScribe --asr-bench <音频目录或单个文件> [选项]
//
// 选项：
//   --asr-engines auto,whisper,apple,funasr,...   只跑指定引擎（默认已装模型的引擎）
//   --translate-modes off,googleV1,microsoft,...  只跑指定翻译通道（默认全部免 key 通道）
//   --target-lang zh-Hans                         目标语言（默认 zh-Hans）
//   --manifest <file.json>                        参考文本清单（对照正确率）
//   --json <out.json>                             写出机器可读结果
//   --live                                        走实时分块链路（transcribeChunk）而非文件转录
//
// `--live` 的意义：字幕场景走的是 `transcribeChunk`，它比文件转录多两层
// 处理 —— `InputBucketing` 补零（对齐 0.5s 桶）与"每轮重发未封口 tail"
// 的重复转写。所以**文件转录快且准不等于实时好用**（实测 SenseVoice
// 文件转录 0.57s/3.6%，但它是 offline 模型，实时链路每轮都要重转整段 tail）。
// 需要评估实时体验时必须带 --live。
//
// 为什么需要它：项目原有的测试只覆盖**纯逻辑层**（断句/环形缓冲/看门狗），
// 以及各 Provider 的**单点**可用性；没有任何测试把「音频 → ASR → 翻译」
// 整条链路串起来跑。于是这类问题会漏网：
//   - 引擎能加载但转不出正确文本（模型损坏 / 架构不匹配）；
//   - ASR 正常但某种翻译通道组合下译文空缺或错位；
//   - 引擎切换后残留状态污染下一次识别。
// 本工作台按「引擎 × 翻译通道」矩阵跑真实音频，输出可对比的分数与文本。
//
// 指标：
//   - ASR：CER（字错率，中文按字）/ WER（词错率，英文按词）+ 参考对照
//   - 翻译：产出是否为空 + 与人工参考译文的一致性（char-F1，宽松指标）
//   - 耗时：ASR 与翻译分段计时（端到端延迟是实时字幕的核心体验指标）

/// 一条评测样本（音频 + 参考文本）。
struct ASRBenchCase: Codable {
    let name: String
    let audioPath: String
    /// 参考识别文本（用于算 CER/WER；为空则只验证"有产出"）。
    let referenceASR: String?
    /// 按目标语言区分的参考译文（键为 locale id，如 "en" / "zh-Hans"）。
    let referenceTranslationByLang: [String: String]
    /// 未分语言时的通用参考译文。
    let referenceTranslationFallback: String?

    /// 取该目标语言的参考译文。
    func referenceTranslation(for lang: String) -> String? {
        referenceTranslationByLang[lang] ?? referenceTranslationFallback
    }
}

/// 一次（样本 × 引擎 × 翻译通道）的结果。
struct ASRBenchResult: Codable {
    let sample: String
    let engine: String
    let translationMode: String
    /// 识别耗时（秒）。
    let asrSeconds: Double
    /// 翻译耗时（秒）。
    let translationSeconds: Double?
    let asrText: String
    let translationText: String?
    /// 识别错误率（0 = 完全一致；nil = 无参考文本）。
    let asrErrorRate: Double?
    /// 译文与参考的一致度（char-F1，0~1；nil = 无参考译文）。
    let translationF1: Double?
    let error: String?
}

@MainActor
enum ASRBench {

    // MARK: 入口

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--asr-bench"), idx + 1 < args.count else { return }
        let inputPath = args[idx + 1]

        let engines = value(of: "--asr-engines", in: args)?
            .split(separator: ",").map(String.init) ?? []
        let modes = value(of: "--translate-modes", in: args)?
            .split(separator: ",").map(String.init) ?? []
        let targetLang = value(of: "--target-lang", in: args) ?? "zh-Hans"
        let manifestPath = value(of: "--manifest", in: args)
        let jsonOut = value(of: "--json", in: args)
        let liveMode = args.contains("--live")

        Task {
            await run(inputPath: inputPath,
                      engineFilter: engines,
                      modeFilter: modes,
                      targetLang: targetLang,
                      manifestPath: manifestPath,
                      jsonOutPath: jsonOut,
                      liveMode: liveMode)
            exit(0)
        }
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: 主流程

    static func run(inputPath: String,
                    engineFilter: [String],
                    modeFilter: [String],
                    targetLang: String,
                    manifestPath: String?,
                    jsonOutPath: String?,
                    liveMode: Bool = false) async {
        print("════════════════════════════════════════════════════════════")
        print(" 声记端到端评测工作台（ASRBench）")
        print("════════════════════════════════════════════════════════════")

        // FunASR 后端注册：正常路径在窗口 onAppear 里做（WhisperASRApp:63），
        // 无窗口的评测模式下 onAppear 永不触发 → 会误报
        // "FunASR runtime unavailable"。这里补注册，保证评测环境与
        // 真实运行环境一致（否则测的是"没插后端"的假失败）。
        FunASRRuntimeRegistry.register(SherpaONNXRuntime())

        // 1) 载入样本
        let cases = loadCases(inputPath: inputPath, manifestPath: manifestPath)
        guard !cases.isEmpty else {
            print("找不到可评测的音频。用法：--asr-bench <目录|文件> [--manifest refs.json]")
            return
        }
        print("样本 \(cases.count) 个")
        for c in cases {
            let ref = c.referenceASR.map { "参考「\($0.prefix(24))…」" } ?? "无参考文本"
            print("  · \(c.name)  \(ref)")
        }

        // 2) 解析引擎列表（默认：auto + 每个已下载模型对应的引擎）
        let engines = resolveEngines(filter: engineFilter)
        print("\n引擎 \(engines.count) 个：\(engines.map(\.rawValue).joined(separator: ", "))")

        // 3) 解析翻译通道
        let modes = resolveModes(filter: modeFilter)
        print("翻译通道 \(modes.count) 个：\(modes.map(\.label).joined(separator: ", "))")

        // 4) 矩阵执行
        var results: [ASRBenchResult] = []
        let service = TranscriptionService()
        let originalEngine = ASREngineSelection.current
        let originalMode = TranslationMode.current
        // targetLanguage 也要一起快照还原：工作台为了逐通道测量会改写它，
        // 漏还原会**改掉用户的实际翻译目标语言**（这是用户配置，不是测试数据）。
        let originalTargetLang = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
        defer {
            // 还原用户配置：工作台不该留下副作用。
            UserDefaults.standard.set(originalEngine.rawValue, forKey: ASREngineSelection.key)
            UserDefaults.standard.set(originalMode.rawValue, forKey: "translationMode")
            UserDefaults.standard.set(originalTargetLang, forKey: "targetLanguage")
        }

        for engine in engines {
            print("\n────────────────────────────────────────────────────────")
            print("引擎：\(engine.rawValue)")
            print("────────────────────────────────────────────────────────")
            UserDefaults.standard.set(engine.rawValue, forKey: ASREngineSelection.key)
            ConfigurationManager.shared.reload()
            _ = service   // 保持实例存活（引擎上下文缓存）

            for c in cases {
                // ---- ASR ----
                let audioURL = URL(fileURLWithPath: c.audioPath)
                let asrStart = Date()
                var asrText = ""
                var asrError: String?
                do {
                    if liveMode {
                        asrText = try await Self.transcribeViaLivePath(
                            service: service, audioURL: audioURL)
                    } else {
                        let result = try await service.transcribe(fileURL: audioURL,
                                                                  language: nil,
                                                                  onProgress: { _ in })
                        asrText = result.fullText.isEmpty
                            ? result.segments.map(\.text).joined()
                            : result.fullText
                    }
                } catch {
                    asrError = error.localizedDescription
                }
                let asrSeconds = Date().timeIntervalSince(asrStart)

                let errorRate = c.referenceASR.map { reference -> Double in
                    Self.errorRate(reference: reference, hypothesis: asrText)
                }

                let asrMark = asrError == nil ? "✓" : "✗"
                let pathTag = liveMode ? "实时" : "文件"
                let errText = errorRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
                print(String(format: "  %@ [%@/%@] %.2fs  错误率 %@",
                             asrMark, c.name, pathTag, asrSeconds, errText))
                print("      识别：\(asrText.isEmpty ? "（空）" : asrText)")
                if let e = asrError { print("      错误：\(e)") }

                // ---- 翻译（按通道逐个跑）----
                for mode in modes {
                    UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
                    UserDefaults.standard.set(targetLang, forKey: "targetLanguage")

                    var translated: String?
                    var translationSeconds: Double?
                    var translationError: String?

                    if mode == .off {
                        translated = nil
                    } else if asrText.isEmpty {
                        translationError = "无识别文本，跳过翻译"
                    } else {
                        let tStart = Date()
                        do {
                            let provider = TranslationManager.provider(for: mode)
                            let result = try await provider.translate(
                                TranslationRequest(text: asrText, targetLanguage: targetLang))
                            translated = result.texts.first
                        } catch {
                            translationError = error.localizedDescription
                        }
                        translationSeconds = Date().timeIntervalSince(tStart)
                    }

                    let f1 = c.referenceTranslation(for: targetLang).flatMap { ref -> Double? in
                        guard let t = translated, !t.isEmpty else { return nil }
                        return Self.charF1(reference: ref, hypothesis: t)
                    }

                    results.append(ASRBenchResult(
                        sample: c.name, engine: engine.rawValue,
                        translationMode: mode.rawValue,
                        asrSeconds: asrSeconds,
                        translationSeconds: translationSeconds,
                        asrText: asrText,
                        translationText: translated,
                        asrErrorRate: errorRate,
                        translationF1: f1,
                        error: asrError ?? translationError))
                }
            }
        }

        // 配置还原由上面的 defer 统一负责（引擎 / 通道 / 目标语言），
        // 此处只刷新一次让设置页读到还原后的值。
        ConfigurationManager.shared.reload()

        // 5) 汇总
        printSummary(results)

        if let jsonOutPath {
            writeJSON(results, to: jsonOutPath)
        }
    }

    // MARK: 引擎 / 通道解析

    static func resolveEngines(filter: [String]) -> [ASREngineSelection] {
        if !filter.isEmpty {
            return filter.compactMap { ASREngineSelection(rawValue: $0) }
        }
        // 默认：每个检测到模型的引擎各跑一次。
        //
        // 不含 `.auto`：auto 会按路径自己解析到一个引擎（实测等于再跑一遍
        // whisper），矩阵里纯属重复采样、拖长总时长。想验证"模型 → 引擎"
        // 路由时用 `--asr-engines auto` 单独跑。
        //
        // 也不含 `.apple`：无授权的 Apple Speech 会弹系统授权框，在无窗口的
        // 评测进程里会打断批量执行。需要时显式传 `--asr-engines apple`。
        var engines: [ASREngineSelection] = []
        let modelsDir = ModelCatalog.modelDirectory
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: modelsDir.path) {
            // 只把**看起来完整**的产物计入：Qwen 的 .gguf 曾出现 32 字节的
            // 认证失败占位文件，直接当模型跑会浪费一轮并报误导性错误。
            let hasWhisper = files.contains {
                $0.hasSuffix(".bin") && fileSize(modelsDir.appendingPathComponent($0)) > 1_000_000
            }
            let hasQwen = files.contains {
                $0.hasSuffix(".gguf") && fileSize(modelsDir.appendingPathComponent($0)) > 1_000_000
            }
            if hasWhisper { engines.append(.whisper) }
            if hasQwen { engines.append(.qwen) }
        }
        return engines
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func resolveModes(filter: [String]) -> [TranslationMode] {
        if !filter.isEmpty {
            return filter.compactMap { TranslationMode(rawValue: $0) }
        }
        // 默认：不翻译 + 三条免 key 公共通道（零配置，最适合做基准）。
        return [.off, .googleV1, .googleV2, .microsoft]
    }

    // MARK: 样本载入

    static func loadCases(inputPath: String, manifestPath: String?) -> [ASRBenchCase] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputPath, isDirectory: &isDir) else { return [] }

        // 参考文本清单：{ "样本名": {"asr": "...", "translation": "...",
        //                          "translation_en": "...", "translation_zh-Hans": "..."} }
        // 多方向音频可共存：翻译参考按目标语言取 `translation_<lang>`，
        // 找不到再回落到通用 `translation`（该样本不参与该方向的对照）。
        var refs: [String: (asr: String?, translation: [String: String], fallback: String?)] = [:]
        if let manifestPath, let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            for (key, value) in raw {
                var perLang: [String: String] = [:]
                for (k, v) in value where k.hasPrefix("translation_") {
                    perLang[String(k.dropFirst("translation_".count))] = v
                }
                refs[key] = (value["asr"], perLang, value["translation"])
            }
        }

        var audioPaths: [String] = []
        if isDir.boolValue {
            let entries = (try? fm.contentsOfDirectory(atPath: inputPath)) ?? []
            let candidates = entries
                .filter { ["wav", "m4a", "mp3", "aiff", "aif", "flac", "mp4"].contains(
                    URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                .sorted()
            // 同名不同扩展（fixture 常同时留 .aiff 与 .wav）只取一个，
            // 否则同一样本被跑两遍、汇总里样本数虚高。
            var seenNames = Set<String>()
            for entry in candidates {
                let base = URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent
                guard !seenNames.contains(base) else { continue }
                seenNames.insert(base)
                // 优先 wav（无需额外解码，评测更纯粹）。
                let preferred = candidates.first {
                    URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == base
                        && URL(fileURLWithPath: $0).pathExtension.lowercased() == "wav"
                }
                audioPaths.append((inputPath as NSString).appendingPathComponent(preferred ?? entry))
            }
        } else {
            audioPaths = [inputPath]
        }

        return audioPaths.map { path in
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let ref = refs[name]
            return ASRBenchCase(
                name: name, audioPath: path,
                referenceASR: ref?.asr,
                referenceTranslationByLang: ref?.translation ?? [:],
                referenceTranslationFallback: ref?.fallback)
        }
    }

    // MARK: 指标

    /// 中文按字、英文按词的归一化错误率（编辑距离 / 参考长度）。
    ///
    /// CER/WER 是 ASR 的标准指标，但要注意它对**标点与全半角**极敏感：
    /// 参考写成 "hello world" 而识别成 "Hello, world." 会凭空产生 100% 错误。
    /// 因此比较前统一做归一化（去标点、小写、全角转半角、压缩空白），
    /// 让指标反映"内容对不对"而不是"标点像不像"。
    nonisolated static func errorRate(reference: String, hypothesis: String) -> Double {
        let ref = normalizeForScoring(reference)
        let hyp = normalizeForScoring(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        let r = segment(normalized: ref)
        let h = segment(normalized: hyp)
        let distance = editDistance(r, h)
        return min(1.0, Double(distance) / Double(r.count))
    }

    /// 切分成计分单元：含 CJK 按字，否则按词。
    nonisolated static func segment(normalized text: String) -> [String] {
        let hasCJK = text.unicodeScalars.contains { $0.value >= 0x2E80 }
        return hasCJK ? text.map(String.init) : text.split(separator: " ").map(String.init)
    }

    /// 归一化：全角→半角、小写、去标点、压缩空白、中文数字→阿拉伯数字。
    ///
    /// 中文数字归一不是"放水"：`百分之十二点五` 与 `12.5%` 是**同一个意思**
    /// 的两种标准写法，whisper 常把口语数字转成阿拉伯形式。不做归一，
    /// CER 会把这种正确的转换记成错误（实测把 0% 的真实错误率抬到 28.6%），
    /// 指标就失去了指示作用。
    nonisolated static func normalizeForScoring(_ text: String) -> String {
        // 先做字符级归一（全角→半角），得到统一的半角标量序列，
        // 再按位置判断小数点——避免在原始串上按下标找错位置。
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            var value = scalar.value
            if value >= 0xFF01, value <= 0xFF5E { value -= 0xFEE0 }
            if value == 0x3000 { value = 0x20 }
            guard let mapped = Unicode.Scalar(value) else { continue }
            scalars.append(mapped)
        }

        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }

        var out = ""
        for (index, scalar) in scalars.enumerated() {
            let ch = Character(scalar)
            // 小数点不能当标点删掉：删了 "12.5" 变 "125"，而参考侧的
            // "十二点五" 会转成 "12.5" —— 两者数值相同却被判成差异
            //（实测把 0% 的错误率抬到 8.3%）。只有**数字之间**的点保留，
            // 句末句点仍按标点剔除。
            if scalar.value == 0x2E,
               index > 0, index + 1 < scalars.count,
               isDigit(scalars[index - 1]), isDigit(scalars[index + 1]) {
                out.append(ch)
                continue
            }
            if ch.isPunctuation || ch.isSymbol { continue }
            out.append(ch)
        }
        return normalizeChineseNumerals(out.lowercased())
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 中文数字表达 → 阿拉伯数字：
    /// `百分之十二点五` → `12.5`、`三十五` → `35`、`一百二十` → `120`。
    /// 只处理常见的口语数值，不追求完整的中文数词文法。
    ///
    /// 关键实现细节（原地踩过两次）：**不能在扫描前用 `replacingOccurrences`
    /// 删掉「百分之」** —— 事后删是没用的，因为数词扫描会先把其中的「百」
    /// 当单位算出 `100分之12.5`。必须在扫描时**前瞻吞掉**这三个字，
    /// 不让它们进入数值缓冲。
    nonisolated static func normalizeChineseNumerals(_ text: String) -> String {
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]

        let chars = Array(text)
        var out = ""
        var buffer = ""            // 累积的数值字符
        var i = 0
        func flush() {
            guard !buffer.isEmpty else { return }
            out += arabic(from: buffer, digits: digits, units: units)
            buffer = ""
        }
        while i < chars.count {
            // 三字词组优先：「百分之」整体吞掉（不产生数值）。
            if i + 2 < chars.count,
               chars[i] == "百", chars[i + 1] == "分", chars[i + 2] == "之" {
                flush()
                i += 3
                continue
            }
            let ch = chars[i]
            // 「点」只在**数字之间**才是小数点（`十二点五` → 12.5）。
            // 否则它是「三点钟」的「点」，属于正文而非数词的一部分：若一律
            // 当小数点吞进缓冲，`三点` 会归一成 `3` 而 `3点` 归一成 `30`，
            // 两种正确写法互相判成 100% 错误（实测把正确识别记成全错）。
            if ch == "点" {
                let hasNumberBefore = !buffer.isEmpty
                let digitAfter = i + 1 < chars.count && digits[chars[i + 1]] != nil
                if hasNumberBefore && digitAfter {
                    buffer.append(ch)
                } else {
                    flush()
                    out.append(ch)
                }
                i += 1
                continue
            }
            if digits[ch] != nil || units[ch] != nil {
                buffer.append(ch)
            } else {
                flush()
                out.append(ch)
            }
            i += 1
        }
        flush()
        return out
    }

    /// 把一段中文数词转成阿拉伯数字字符串（支持「十/百/千/万」与「点」）。
    nonisolated private static func arabic(from text: String,
                               digits: [Character: Int],
                               units: [Character: Int]) -> String {
        var total = 0
        var section = 0     // 当前「万」以下的小节
        var number = 0      // 当前待落位的数字
        var seenUnit = false
        var decimal: String? = nil

        for ch in text {
            if ch == "点" { decimal = ""; continue }
            if decimal != nil {
                // 小数部分：
                if let d = digits[ch] { decimal?.append(String(d)) }
                continue
            }
            if let d = digits[ch] {
                number = d
            } else if let u = units[ch] {
                seenUnit = true
                if u == 10000 {
                    section = (section + max(number, 1)) * 10000
                    total += section
                    section = 0
                } else {
                    // "十五" → 15（十前无数字时按 1 计）
                    section += max(number, 1) * u
                }
                number = 0
            }
        }
        var value = total + section + number
        // 纯数字串（无单位）时 value == number，直接用它；
        // 但 "十" 单独出现（number 已归零）要补回 10。
        if !seenUnit { value = number }
        else if value == 0, !text.isEmpty { value = number }

        var result = String(value)
        if let dec = decimal, !dec.isEmpty { result += "." + dec }
        return result
    }

    /// Levenshtein 编辑距离（滚动数组，O(min(n,m)) 空间）。
    nonisolated static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,        // 删除
                                 current[j - 1] + 1,     // 插入
                                 previous[j - 1] + cost) // 替换
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 译文与参考的字级 F1（宽松一致性指标）。
    ///
    /// 翻译没有唯一正确答案（"今天天气很好" → "The weather is nice today"
    /// 与 "It's a beautiful day" 都对），所以这里**不**用错误率判好坏，
    /// 只用来发现"译文完全跑偏/错位/为空"这类硬故障。
    nonisolated static func charF1(reference: String, hypothesis: String) -> Double {
        let refChars = Set(normalizeForScoring(reference).map(String.init))
        let hypChars = Set(normalizeForScoring(hypothesis).map(String.init))
        guard !refChars.isEmpty || !hypChars.isEmpty else { return 1 }
        let overlap = refChars.intersection(hypChars).count
        guard overlap > 0 else { return 0 }
        let precision = Double(overlap) / Double(hypChars.count)
        let recall = Double(overlap) / Double(refChars.count)
        return 2 * precision * recall / (precision + recall)
    }

    // MARK: 汇总输出

    static func printSummary(_ results: [ASRBenchResult]) {
        print("\n════════════════════════════════════════════════════════════")
        print(" 汇总（引擎 × 翻译通道）")
        print("════════════════════════════════════════════════════════════")

        // ASR 侧：按引擎汇总
        print("\n【识别】")
        let byEngine = Dictionary(grouping: results, by: \.engine)
        for engine in byEngine.keys.sorted() {
            let items = byEngine[engine] ?? []
            // 同一引擎对同一样本跑了多条翻译通道 → 识别结果重复，按样本去重。
            var seenSamples: [String: ASRBenchResult] = [:]
            for row in items where seenSamples[row.sample] == nil {
                seenSamples[row.sample] = row
            }
            var errs: [Double] = []
            var times: [Double] = []
            var failures = 0
            for (_, row) in seenSamples {
                times.append(row.asrSeconds)
                if let e = row.asrErrorRate { errs.append(e) }
                if row.asrText.isEmpty { failures += 1 }
            }
            let avgErr = errs.isEmpty ? nil : errs.reduce(0, +) / Double(errs.count)
            let avgTime = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
            let errText = avgErr.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
            print(pad(engine, 10)
                  + " 平均错误率 " + pad(errText, 9)
                  + String(format: "平均耗时 %.2fs", avgTime)
                  + "  样本 \(seenSamples.count)  失败 \(failures)")
        }

        // 翻译侧：按通道汇总
        print("\n【翻译】")
        let translationRows = results.filter { $0.translationMode != TranslationMode.off.rawValue }
        let byMode = Dictionary(grouping: translationRows, by: \.translationMode)
        for mode in byMode.keys.sorted() {
            let items = byMode[mode] ?? []
            // 只统计"有识别文本"的行（否则无输入，失败不算通道问题）
            let applicable = items.filter { !$0.asrText.isEmpty }
            let ok = applicable.filter { ($0.translationText?.isEmpty == false) && $0.error == nil }
            let empty = applicable.filter { $0.translationText?.isEmpty != false }
            let errored = applicable.filter { $0.error != nil }
            let times = applicable.compactMap(\.translationSeconds)
            let f1s = applicable.compactMap(\.translationF1)
            let avgF1 = f1s.isEmpty ? nil : f1s.reduce(0, +) / Double(f1s.count)
            let avgTime = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
            let f1Text = avgF1.map { String(format: "%.2f", $0) } ?? "—"
            print(pad(mode, 12)
                  + "成功 \(ok.count)/\(applicable.count)"
                  + "  空译文 \(empty.count)  出错 \(errored.count)"
                  + String(format: "  平均耗时 %.2fs", avgTime)
                  + "  一致度 " + f1Text)
            if let firstError = errored.first, let msg = firstError.error {
                print("      例：\(firstError.sample) → \(msg.prefix(110))")
            }
        }

        // 交叉：找出"某引擎在特定通道下失败"的组合
        // （不翻译模式本来就没有译文，不算异常）
        print("\n【异常组合】（ASR 成功但译文为空/报错）")
        let suspicious = results.filter {
            $0.translationMode != TranslationMode.off.rawValue
                && !$0.asrText.isEmpty
                && ($0.error != nil || $0.translationText?.isEmpty != false)
        }
        if suspicious.isEmpty {
            print("  无")
        } else {
            for row in suspicious.prefix(12) {
                let reason = row.error ?? "译文为空"
                print("  \(row.engine) × \(row.translationMode) × \(row.sample)：\(reason.prefix(90))")
            }
        }
    }

    /// 左对齐补空格（避免 `String(format:)` 配 `%@` + `NSString.utf8String!`
    /// ——后者对某些字符串会返回 nil 并解包崩溃，是上面汇总打印崩溃的成因）。
    private static func pad(_ text: String, _ width: Int) -> String {
        let cjk = text.unicodeScalars.filter { $0.value >= 0x2E80 }.count
        let visual = text.count + cjk          // 中日韩字符按 2 列宽估算
        guard visual < width else { return text + " " }
        return text + String(repeating: " ", count: width - visual)
    }

    /// 经**实时分块链路**转写（模拟 ASRManager 的行为）。
    ///
    /// 与文件转录的两点关键差异，正是需要单独测的原因：
    /// 1. 走 `InputBucketing` 补零（对齐 0.5s 桶）——文件转录不补零；
    /// 2. 每轮重发"未封口 tail"。offline 引擎（whisper / SenseVoice）
    ///    按无状态处理会**重复转写重叠音频**，流式引擎则由水位线裁剪。
    ///
    /// 这里按累积 1s 一喂模拟，末尾再把最后一轮结果作为终值——足够暴露
    /// "实时路径是否可用/是否比文件路径差"，不追求复刻 ASRManager 的
    /// 全部自适应逻辑（那需要真实录音时钟）。
    static func transcribeViaLivePath(service: TranscriptionService,
                                      audioURL: URL) async throws -> String {
        let samples = try await AudioLoader.loadSamples(url: audioURL)
        guard !samples.isEmpty else { return "" }

        // 模拟录音进度：每次喂入 1s，绝对区间随累积增长（与 ASRManager 一致）。
        let step = 16000
        var fed = 0
        var lastText = ""
        while fed < samples.count {
            let end = min(fed + step, samples.count)
            let chunk = samples[fed..<end]
            let result = try await service.transcribeChunk(
                samples: chunk, absoluteRange: fed..<end)
            // 停口前的中间结果只用于驱动状态；最终以最后一轮为准。
            let text = result.segments.map(\.text).joined()
            if !text.isEmpty { lastText = text }
            fed = end
        }
        // 收尾：把整段当作未封口 tail 再转一次，拿到最终文本
        //（实时链路里这一步由"停顿封口"触发）。
        let final = try await service.transcribeChunk(
            samples: samples[0..<samples.count], absoluteRange: nil)
        let finalText = final.segments.map(\.text).joined()
        return finalText.isEmpty ? lastText : finalText
    }

    static func writeJSON(_ results: [ASRBenchResult], to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(results) else {
            print("⚠️ 结果序列化失败")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("\n结果已写入：\(path)")
        } catch {
            print("⚠️ 结果写入失败：\(error.localizedDescription)")
        }
    }
}

#endif
