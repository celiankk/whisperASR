import Foundation

// MARK: - 引擎性能画像（ASRPerformanceProfile）
//
// 描述性元数据（UI 展示 / 未来自动路由的输入），不影响运行时行为：
// 相对速度档位、内存量级、首次加载成本。

struct ASRPerformanceProfile: Equatable, Sendable {
    /// 相对推理速度（1 = 最快档；数值越大越慢）。
    let speedRating: Int
    /// 典型常驻内存量级（MB，粗粒度；-1 = 不定/取决于端点）。
    let typicalMemoryMB: Int
    /// 首次使用成本（模型下载 / 语言包下载 / 无）。
    let setupCost: SetupCost

    enum SetupCost: String, Sendable {
        case none            // 系统内置（Apple Speech 已有语言包时）
        case languagePack    // 语言包级下载（Apple 新语言 / FunASR 数百 MB）
        case modelDownload   // 模型文件下载（GB 级）
    }
}

// MARK: - 能力注册表（ASRCapabilityRegistry）
//
// 引擎 → 能力的唯一查询口。静态注册表（引擎集合编译期固定），
// UI / 路由按 capability(for:) 取数据渲染，不散落引擎分支。
//
// 数据事实来源：
// - streaming/partial 语义与 Provider.isStreamingEngine 声明一致；
// - timestamp 区分引擎原生（whisper/FunASR token 级/Apple 段 range）
//   与字符估算（Qwen/Nemotron estimateSegments，标 false）；
// - 语言表：whisper 全表来自 CWhisper；Qwen 自动检测不可枚举；
//   Apple 跟随系统语言包；FunASR 按模型细分（SenseVoice 四语提示 /
//   Paraformer 中英双语内置 / Nano 多语言）。

final class ASRCapabilityRegistry: @unchecked Sendable {
    static let shared = ASRCapabilityRegistry()

    /// 全部引擎（固定顺序：UI 遍历渲染顺序即此）。
    static let allEngines: [ASREngineType] = [
        .whisper, .qwen3asr, .nemotron, .online, .remote, .apple, .funasr
    ]

    private var capabilities: [ASREngineType: ASRCapability] = [:]
    /// capabilities/funasrCache 的访问锁（@unchecked Sendable：查询来自
    /// 主线程 UI 与测试线程）。
    private let lock = NSLock()
    /// FunASR 能力缓存（按模型目录名失效）：funasrCapability() 每次读盘
    /// （resolveLiveModelPath 的 fileExists + 目录文件特征探测），而
    /// ASRCapabilitySummaryView 的 body 每帧查询——设置页高频重绘时
    /// 造成无谓磁盘 IO。模型切换时目录名变化，缓存自动失效。
    private var funasrCache: (directoryName: String, capability: ASRCapability)?

    /// 测试可实例化（独立注册表，不污染 shared）。
    init() {
        for capability in defaults() {
            register(capability)
        }
    }

    /// 注册/覆盖能力描述（测试可注入；生产用 defaults()）。
    func register(_ capability: ASRCapability) {
        capabilities[capability.engine] = capability
    }

    /// 引擎能力查询。所有内建引擎必须已注册——缺失是编程错误，
    /// 返回兜底描述并断言（debug 下炸出「engine exists but
    /// capability missing」）。
    func capability(for engine: ASREngineType) -> ASRCapability {
        if engine == .funasr {
            return lock.withLock { cachedFunASRCapability() }
        }
        return lock.withLock {
            if let capability = capabilities[engine] { return capability }
            assertionFailure("ASRCapability missing for engine \(engine.rawValue)")
            return ASRCapability(
                engine: engine,
                supportsStreaming: false,
                supportsPartialResult: true,
                supportsTimestamp: false,
                supportedLanguages: [],
                requiresNetwork: false,
                recommendedMode: .balanced)
        }
    }

    /// 全部已注册能力（设置页遍历渲染用；固定引擎顺序）。
    var all: [ASRCapability] {
        Self.allEngines.compactMap { capabilities[$0] }
    }

    // MARK: 内建引擎默认能力

    private func defaults() -> [ASRCapability] {
        let whisperLanguages = TranscriptionService.availableLanguages().map(\.code)
        return [
            // Whisper：非流式每轮重转录 tail（partial 可用）；原生时间戳；
            // 手动语言全表；本地；大模型精度优先。
            ASRCapability(
                engine: .whisper,
                supportsStreaming: false,
                supportsPartialResult: true,
                supportsTimestamp: true,
                supportedLanguages: whisperLanguages,
                requiresNetwork: false,
                recommendedMode: .accuracy),
            // Qwen3-ASR：30 语种 + 方言自动检测（不可手动指定→空表）；
            // 时间戳为字符估算。
            ASRCapability(
                engine: .qwen3asr,
                supportsStreaming: false,
                supportsPartialResult: true,
                supportsTimestamp: false,
                supportedLanguages: [],
                requiresNetwork: false,
                recommendedMode: .accuracy),
            // Nemotron：FluidAudio/Core ML 本地引擎，时间戳同为估算。
            ASRCapability(
                engine: .nemotron,
                supportsStreaming: false,
                supportsPartialResult: true,
                supportsTimestamp: false,
                supportedLanguages: whisperLanguages,
                requiresNetwork: false,
                recommendedMode: .balanced),
            // Online API：网络请求；响应无词级时间戳（整段回落）。
            ASRCapability(
                engine: .online,
                supportsStreaming: false,
                supportsPartialResult: true,
                supportsTimestamp: false,
                supportedLanguages: whisperLanguages,
                requiresNetwork: true,
                recommendedMode: .balanced),
            // 远程自托管端点：网络请求（局域网 GPU 机器）；协议同 OpenAI
            // Whisper API，无原生时间戳；密钥可选。
            ASRCapability(
                engine: .remote,
                supportsStreaming: false,
                supportsPartialResult: true,
                supportsTimestamp: false,
                supportedLanguages: whisperLanguages,
                requiresNetwork: true,
                recommendedMode: .balanced),
            // Apple Speech：系统流式引擎（增量会话）；段级原生时间戳；
            // 语言跟随系统语言包（运行时查询 AppleLanguageManager，
            // 静态描述不枚举）；macOS 26+。
            ASRCapability(
                engine: .apple,
                supportsStreaming: true,
                supportsPartialResult: true,
                supportsTimestamp: true,
                supportedLanguages: [],
                requiresNetwork: false,
                recommendedMode: .realtime),
            // FunASR（按当前模型类型细分）：streaming 语义随模型；
            // SenseVoice/Paraformer 时间戳为 token 级原生。
            funasrCapability()
        ]
    }

    /// FunASR 能力按所选模型折算：paraformer-streaming 是流式引擎，
    /// 其余 offline 整段替换；语言支持按模型族（SenseVoice 四语 +
    /// 粤语提示 / Paraformer 中英内置 / Nano 多语言自动检测）。
    /// FunASR 能力缓存查询：模型目录名未变时直接返回缓存
    ///（目录名含模型身份——catalog 约定 fileName；自定义目录按文件
    /// 特征探测的结果也随目录内容变化，名字不变内容变的窗口极小，
    /// 设置页展示场景可接受）。
    private func cachedFunASRCapability() -> ASRCapability {
        let directoryName = (ModelPathResolver.resolveLiveModelPath() as NSString).lastPathComponent
        if let funasrCache, funasrCache.directoryName == directoryName {
            return funasrCache.capability
        }
        let capability = funasrCapability()
        funasrCache = (directoryName, capability)
        return capability
    }

    private func funasrCapability() -> ASRCapability {
        let modelType = FunASRModelConfig.config(
            for: URL(fileURLWithPath: ModelPathResolver.resolveLiveModelPath(),
                     isDirectory: true)).modelType
        let languages: [String]
        switch modelType {
        case .senseVoiceSmall:
            languages = ["zh", "en", "ja", "ko", "yue"]
        case .paraformerStreaming, .paraformerZH:
            languages = ["zh", "en"]
        case .funASRNano:
            languages = []
        }
        return ASRCapability(
            engine: .funasr,
            supportsStreaming: modelType.isStreaming,
            supportsPartialResult: true,
            supportsTimestamp: true,
            supportedLanguages: languages,
            requiresNetwork: false,
            recommendedMode: modelType == .paraformerZH ? .accuracy : .realtime)
    }
}
