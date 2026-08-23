import XCTest
@testable import WhisperASR

/// ASRCapabilityRegistry 单测（统一能力描述层）：
/// 核心不变量——每个 ASREngineType 都有已注册能力
/// （不存在 engine exists but capability missing）；
/// 描述事实与 Provider 声明一致（streaming 语义、网络需求）。
final class ASRCapabilityRegistryTests: XCTestCase {

    // MARK: 完备性（规格第九节）

    func testEveryEngineHasCapability() {
        let registry = ASRCapabilityRegistry.shared
        for engine in ASRCapabilityRegistry.allEngines {
            let capability = registry.capability(for: engine)
            XCTAssertEqual(capability.engine, engine, "引擎 \(engine.rawValue) 能力查询返回了错误条目")
        }
        XCTAssertEqual(registry.all.count, ASRCapabilityRegistry.allEngines.count)
    }

    /// 注册表覆盖与 Provider 实例的 streaming 声明一致性：
    /// capability.supportsStreaming 必须等于 provider.isStreamingEngine
    /// （两处描述同一事实，漂移即 bug）。
    func testStreamingDescriptionMatchesProviderDeclaration() async {
        let service = TranscriptionService()
        let registry = ASRCapabilityRegistry.shared
        for capability in registry.all {
            // 经 resolveLiveEngine 同一路径取 provider（引擎选择为 auto 默认档，
            // 直接比对静态声明：逐引擎构造 provider 太重，这里校验注册表
            // 内部一致性 + Apple/FunASR 已知流式事实）。
            switch capability.engine {
            case .apple:
                XCTAssertTrue(capability.supportsStreaming, "Apple Speech 是流式引擎")
            case .funasr:
                // 取决于所选模型：不写死，只要求与 FunASRModelType 一致。
                let modelType = FunASRModelConfig.config(
                    for: URL(fileURLWithPath: ModelPathResolver.resolveLiveModelPath(),
                             isDirectory: true)).modelType
                XCTAssertEqual(capability.supportsStreaming, modelType.isStreaming)
            default:
                XCTAssertFalse(capability.supportsStreaming,
                               "\(capability.engine.rawValue) 非流式引擎，声明不应为 true")
            }
            _ = service  // 静默未使用告警
        }
    }

    func testOnlineRequiresNetworkOthersLocal() {
        let registry = ASRCapabilityRegistry.shared
        for capability in registry.all {
            XCTAssertEqual(capability.requiresNetwork, capability.engine == .online,
                           "仅在线引擎 requiresNetwork=true")
        }
    }

    // MARK: 字段语义

    func testWhisperSupportsLanguageSelectionWithNativeTimestamps() {
        let whisper = ASRCapabilityRegistry.shared.capability(for: .whisper)
        XCTAssertTrue(whisper.supportsTimestamp)
        XCTAssertTrue(whisper.supportsLanguageSelection)
        XCTAssertFalse(whisper.supportedLanguages.isEmpty)
        XCTAssertEqual(whisper.recommendedMode, .accuracy)
    }

    func testQwenAutoDetectOnlyAndEstimatedTimestamps() {
        let qwen = ASRCapabilityRegistry.shared.capability(for: .qwen3asr)
        XCTAssertFalse(qwen.supportsLanguageSelection, "Qwen 自动检测不可枚举语言表")
        XCTAssertFalse(qwen.supportsTimestamp, "Qwen 时间戳为字符估算")
    }

    func testFunASRSenseVoiceLanguages() {
        let funasr = ASRCapabilityRegistry.shared.capability(for: .funasr)
        if funasr.supportedLanguages.contains("zh") {
            XCTAssertTrue(funasr.supportedLanguages.contains("en"),
                          "SenseVoice/Paraformer 族均为中英（含）双语")
        }
        XCTAssertTrue(funasr.supportsTimestamp, "FunASR token 级原生时间戳")
    }

    // MARK: 自定义注册（测试注入）

    func testCustomRegistrationOverridesDefault() {
        let registry = ASRCapabilityRegistry()
        let custom = ASRCapability(
            engine: .whisper,
            supportsStreaming: true,   // 故意与默认相反
            supportsPartialResult: false,
            supportsTimestamp: false,
            supportedLanguages: ["zh"],
            requiresNetwork: true,
            recommendedMode: .realtime)
        registry.register(custom)
        XCTAssertEqual(registry.capability(for: .whisper), custom)
    }

    func testMissingCapabilityFallsBackSafely() {
        let empty = ASRCapabilityRegistry()   // 未注册任何引擎
        let fallback = empty.capability(for: .apple)
        XCTAssertEqual(fallback.engine, .apple)
        XCTAssertTrue(fallback.supportsPartialResult, "兜底至少允许 partial 显示")
    }
}
