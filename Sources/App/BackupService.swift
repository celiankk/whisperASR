import Foundation

/// Exports and restores app configuration as a single portable JSON file, so a
/// user moving to a new Mac can carry over their settings.
///
/// Configuration is the only thing that lives outside the Recordings and
/// Transcriptions folders. The user copies those two folders manually; the
/// transcripts themselves come straight from the copied Transcriptions folder
/// (read by `TranscriptionStore.loadAll()`), and each recording's audio link is
/// auto-repaired on load by `TranscriptionStore.resolveRecordingURL` — which
/// re-links by filename when the stored absolute path (with the old username)
/// no longer resolves. So the backup deliberately does *not* duplicate
/// transcription metadata; it only carries the settings.
enum BackupService {

    /// Bumped only if the on-disk schema changes incompatibly.
    static let formatVersion = 1

    // MARK: - DTOs

    struct BackupFile: Codable {
        var version: Int
        var createdAt: Date
        var appVersion: String?
        var configuration: BackupConfiguration
    }

    /// Every persisted UserDefaults setting. All optional so a future/older
    /// backup that omits a key simply leaves the current value untouched.
    struct BackupConfiguration: Codable {
        var transcriptFontSize: String?
        var selectedModelFile: String?
        var modelPath: String?
        var targetLanguage: String?
        var translationEndpoint: String?
        var translationModel: String?
        var translationAPIKey: String?
        var translationMode: String?
        var translationTimeout: Double?
        var translationMaxContext: Int?
        var translationTemperature: Double?
        var liveTranslationPref: Bool?
        var recentRecordingApps: [String]?
        /// Meeting-minutes prompts as their raw JSON (the UserDefaults blob).
        var minutesPromptsJSON: String?
        var selectedMinutesPromptID: String?
        var minutesContextTokens: Int?

        /// 七个配置分区**实际用键**的原始值快照（键名 = UserDefaults 键，
        /// 与历史版本完全一致）。上面那些经典字段保留是为了兼容旧备份；
        /// 新增覆盖项只需登记进 `coveredKeys`，不必逐个加 DTO 字段——
        /// 此前只备份 16 个键，与「导出全部设置」的文案不符。
        /// 旧版本导出的备份没有本字段（nil）→ 只应用经典字段。
        var settings: [String: SettingValue]?
    }

    /// 设置值（保留 UserDefaults 的原生类型，恢复后类型不漂移）。
    /// 自定义 Coding 是为了备份文件可读：{"t":"int","v":8080}。
    enum SettingValue: Codable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case strings([String])

        private enum CodingKeys: String, CodingKey { case type = "t", value = "v" }

        /// 写回 UserDefaults 的原始值。
        var rawValue: Any {
            switch self {
            case .string(let v): return v
            case .int(let v): return v
            case .double(let v): return v
            case .bool(let v): return v
            case .strings(let v): return v
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "string": self = .string(try container.decode(String.self, forKey: .value))
            case "int": self = .int(try container.decode(Int.self, forKey: .value))
            case "double": self = .double(try container.decode(Double.self, forKey: .value))
            case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
            case "strings": self = .strings(try container.decode([String].self, forKey: .value))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "未知的设置值类型")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .string(let v):
                try container.encode("string", forKey: .type)
                try container.encode(v, forKey: .value)
            case .int(let v):
                try container.encode("int", forKey: .type)
                try container.encode(v, forKey: .value)
            case .double(let v):
                try container.encode("double", forKey: .type)
                try container.encode(v, forKey: .value)
            case .bool(let v):
                try container.encode("bool", forKey: .type)
                try container.encode(v, forKey: .value)
            case .strings(let v):
                try container.encode("strings", forKey: .type)
                try container.encode(v, forKey: .value)
            }
        }
    }

    /// 备份覆盖的键（ConfigurationManager 七个分区实际使用的键）。
    /// 会议纪要提示词的三个键由上面的经典字段单独承载（含 Data blob），
    /// 故不在此登记，避免重复与类型转换。
    static let coveredKeys: [String] = [
        // general：转录字体 / 录制后生成转录记录 / 本地 API 服务器
        "transcriptFontSize",
        "enableTranscriptRecord",
        "apiServerEnabled",
        "apiServerPort",
        "apiServerToken",
        "apiServerAllowLAN",
        "apiServerVerboseLogging",
        // asr：引擎 / 模型 / 在线与远程端点 / 分片 / 补零 / 下载源 / Apple 语言
        "selectedModelFile",
        "modelPath",
        ASREngineSelection.key,
        "asrLanguage",
        OnlineASRApiType.key,
        OnlineASRConfig.Keys.enabled,
        OnlineASRConfig.Keys.baseURL,
        OnlineASRConfig.Keys.apiKey,
        OnlineASRConfig.Keys.model,
        OnlineASRConfig.Keys.streaming,
        OnlineASRConfig.Keys.mimoLanguage,
        RemoteASRConfig.Keys.enabled,
        RemoteASRConfig.Keys.baseURL,
        RemoteASRConfig.Keys.apiKey,
        RemoteASRConfig.Keys.model,
        AudioChunkingMode.key,
        AudioChunkingConfig.Keys.minSeconds,
        AudioChunkingConfig.Keys.maxWaitSeconds,
        ASRConfiguration.padSecondsKey,
        ASRConfiguration.modelDownloadSourceKey,
        "appleSpeechLocale",
        // translation：方式 / 端点 / 密钥 / 参数 / 提示词 / 思考控制 / 上下文句数
        "targetLanguage",
        "translationMode",
        "lastActiveTranslationMode",
        TranslationService.ConfigKeys.endpoint,
        TranslationService.ConfigKeys.apiKey,
        TranslationService.ConfigKeys.model,
        TranslationService.ConfigKeys.timeout,
        TranslationService.ConfigKeys.maxContext,
        TranslationService.ConfigKeys.temperature,
        TranslationService.ConfigKeys.systemPrompt,
        "translationPromptPreset",
        TranslationConfiguration.thinkingControlKey,
        TranslationConfiguration.contextRoundsKey,
        // subtitle：字幕浮层样式
        "subtitleOverlaySourceFontSize",
        "subtitleOverlayTranslationFontSize",
        "subtitleOverlayBorderOpacity",
        "subtitleMaxLines",
        "subtitleHorizontalAlignment",
        "subtitleClearDelay",
        "subtitleFrameWidth",
        "subtitleFrameHeight",
        "subtitleBackgroundOpacity",
        "subtitleEditBorderVisible",
        "subtitleEditBorderColorHex",
        "subtitleEditBorderOpacity",
        "subtitleFontWeight",
        "subtitleLineSpacing",
        // audio / window
        AudioConfiguration.includeMicrophoneKey,
        "floatingOverlayAutoHide",
        "recentRecordingApps",
        "liveTranslationPref",
        // asrPrompt：热词注入
        ASRPromptConfiguration.keyEnabled,
        ASRPromptConfiguration.keySource,
        ASRPromptConfiguration.keyCustom,
        ASRPromptConfiguration.keyScene,
        ASRPromptConfiguration.keyKeywords,
        ASRPromptConfiguration.keyAIGenerated,
    ]

    /// 读取一个键的原始值；nil = 该键从未设置 → 备份中不出现 → 恢复时不覆盖。
    static func rawValue(_ defaults: UserDefaults, _ key: String) -> SettingValue? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        if let string = raw as? String { return .string(string) }
        if let array = raw as? [String] { return .strings(array) }
        if let number = raw as? NSNumber {
            // Bool 在 UserDefaults 里同样是 NSNumber：不按 CFBoolean 区分的话
            // true 会以 1 落盘，恢复后类型漂移（例如开关变数字）。
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" { return .double(number.doubleValue) }
            return .int(number.intValue)
        }
        return nil
    }

    // MARK: - Export

    static func makeBackup() -> BackupFile {
        let d = UserDefaults.standard
        let config = BackupConfiguration(
            transcriptFontSize: d.string(forKey: "transcriptFontSize"),
            selectedModelFile: d.string(forKey: "selectedModelFile"),
            modelPath: d.string(forKey: "modelPath"),
            targetLanguage: d.string(forKey: "targetLanguage"),
            translationEndpoint: d.string(forKey: "translationEndpoint"),
            translationModel: d.string(forKey: "translationModel"),
            translationAPIKey: d.string(forKey: "translationAPIKey"),
            translationMode: d.string(forKey: "translationMode"),
            translationTimeout: d.object(forKey: TranslationService.ConfigKeys.timeout) == nil
                ? nil : d.double(forKey: TranslationService.ConfigKeys.timeout),
            translationMaxContext: d.object(forKey: TranslationService.ConfigKeys.maxContext) == nil
                ? nil : d.integer(forKey: TranslationService.ConfigKeys.maxContext),
            translationTemperature: d.object(forKey: TranslationService.ConfigKeys.temperature) == nil
                ? nil : d.double(forKey: TranslationService.ConfigKeys.temperature),
            liveTranslationPref: d.object(forKey: "liveTranslationPref") == nil
                ? nil : d.bool(forKey: "liveTranslationPref"),
            recentRecordingApps: d.stringArray(forKey: "recentRecordingApps"),
            minutesPromptsJSON: d.data(forKey: MinutesPromptStore.promptsKey)
                .flatMap { String(data: $0, encoding: .utf8) },
            selectedMinutesPromptID: d.string(forKey: MinutesPromptStore.selectedKey),
            minutesContextTokens: d.object(forKey: MinutesPromptStore.contextTokensKey) == nil
                ? nil : d.integer(forKey: MinutesPromptStore.contextTokensKey),
            // 七个分区的实际用键快照（键未设置则不出现 → 恢复时不覆盖）。
            settings: coveredKeys.reduce(into: [String: SettingValue]()) { result, key in
                if let value = rawValue(d, key) { result[key] = value }
            }
        )

        return BackupFile(
            version: formatVersion,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            configuration: config
        )
    }

    static func encode(_ backup: BackupFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupFile.self, from: data)
    }

    // MARK: - Restore

    /// Writes the backed-up configuration back to UserDefaults. Touches
    /// ModelManager and UserDefaults, so it runs on the main actor. Only keys
    /// present in the backup are written, so missing keys leave the current
    /// value intact.
    @MainActor
    static func restore(_ backup: BackupFile) {
        let c = backup.configuration
        let d = UserDefaults.standard
        func set(_ value: String?, _ key: String) {
            if let value { d.set(value, forKey: key) }
        }
        // ① 七个分区的原始值快照（新版备份）：键名与历史版本完全一致。
        if let settings = c.settings {
            for (key, value) in settings { d.set(value.rawValue, forKey: key) }
        }
        // ② 经典字段：旧版本备份的兼容路径（也覆盖新版，值同源，幂等）。
        set(c.transcriptFontSize, "transcriptFontSize")
        set(c.selectedModelFile, "selectedModelFile")
        set(c.modelPath, "modelPath")
        set(c.targetLanguage, "targetLanguage")
        set(c.translationEndpoint, "translationEndpoint")
        set(c.translationModel, "translationModel")
        set(c.translationAPIKey, "translationAPIKey")
        set(c.translationMode, "translationMode")
        if let timeout = c.translationTimeout {
            d.set(timeout, forKey: TranslationService.ConfigKeys.timeout)
        }
        if let maxContext = c.translationMaxContext {
            d.set(maxContext, forKey: TranslationService.ConfigKeys.maxContext)
        }
        if let temperature = c.translationTemperature {
            d.set(temperature, forKey: TranslationService.ConfigKeys.temperature)
        }
        if let pref = c.liveTranslationPref { d.set(pref, forKey: "liveTranslationPref") }
        if let apps = c.recentRecordingApps { d.set(apps, forKey: "recentRecordingApps") }
        if let prompts = c.minutesPromptsJSON?.data(using: .utf8) {
            d.set(prompts, forKey: MinutesPromptStore.promptsKey)
        }
        set(c.selectedMinutesPromptID, MinutesPromptStore.selectedKey)
        if let tokens = c.minutesContextTokens { d.set(tokens, forKey: MinutesPromptStore.contextTokensKey) }
        MinutesPromptStore.shared.reloadFromDefaults()

        // ModelManager caches the selection in a stored property; nudge it so the
        // toolbar/Settings reflect the restored choice. refresh() will clear it
        // again if that model isn't downloaded on this Mac yet — which is correct,
        // and it re-selects automatically once the model is downloaded.
        if let sel = c.selectedModelFile {
            ModelManager.shared.selectedFileName = sel
        }
        ModelManager.shared.refresh()

        // ③ 运行时同步：只写 UserDefaults 不会生效——运行时状态（翻译方式、
        // 字幕浮层样式、浮层偏好）由 AppState 持有内存副本，而且 AppState 的
        // setter 会把内存旧值写回磁盘，用户下一次动设置就把刚恢复的值覆盖掉。
        // 经配置中心（已 attach AppState）统一应用（幂等）。
        ConfigurationManager.shared.reloadAndApplyRuntime()
    }
}
