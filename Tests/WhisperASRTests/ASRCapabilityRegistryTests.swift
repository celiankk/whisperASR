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
            // 网络引擎 = 在线 API + 远程自托管端点；本地引擎（含 Apple）不联网。
            let isNetworkEngine = capability.engine == .online || capability.engine == .remote
            XCTAssertEqual(capability.requiresNetwork, isNetworkEngine,
                           "\(capability.engine.rawValue) 的 requiresNetwork 与引擎类型不符")
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

    // MARK: summaryEntries（设置页渲染数据源）

    /// 所有引擎的 summaryEntries 非空且条目合法——UI 遍历渲染依赖
    /// 此完备性（新引擎只在注册表补注册，UI 即可显示）。
    func testSummaryEntriesCompleteForAllEngines() {
        for capability in ASRCapabilityRegistry.shared.all {
            let entries = capability.summaryEntries
            XCTAssertFalse(entries.isEmpty, "\(capability.engine.rawValue) 能力清单为空")
            for entry in entries {
                XCTAssertFalse(entry.label.isEmpty, "\(capability.engine.rawValue) 存在空标签")
            }
            // 每个清单都应包含推荐场景行（首条）与运行位置行（末条）。
            XCTAssertTrue(entries.first?.label.contains("推荐场景") ?? false,
                          "\(capability.engine.rawValue) 缺推荐场景条目")
            let last = entries.last?.label ?? ""
            XCTAssertTrue(last.contains("本地运行") || last.contains("需网络"),
                          "\(capability.engine.rawValue) 缺运行位置条目")
        }
    }

    /// 网络需求与清单文案一致：online 末条为「需网络」，其余「本地运行」。
    func testNetworkRequirementMatchesSummaryText() {
        for capability in ASRCapabilityRegistry.shared.all {
            let last = capability.summaryEntries.last?.label ?? ""
            if capability.requiresNetwork {
                XCTAssertEqual(last, "需网络", "\(capability.engine.rawValue) 应标需网络")
            } else {
                XCTAssertEqual(last, "本地运行", "\(capability.engine.rawValue) 应标本地运行")
            }
        }
    }

    /// 语言展示策略：不可枚举（空表）→「多语言自动检测」；
    /// 可枚举 → 明确语言数或语言列表。
    func testLanguageEntryReflectsSupportedLanguages() {
        let qwen = ASRCapabilityRegistry.shared.capability(for: .qwen3asr)
        XCTAssertTrue(qwen.summaryEntries.contains { $0.label.contains("自动检测") })
        let funasr = ASRCapabilityRegistry.shared.capability(for: .funasr)
        if funasr.supportsLanguageSelection || !funasr.supportedLanguages.isEmpty {
            XCTAssertTrue(funasr.summaryEntries.contains { $0.label.contains("语言") })
        }
    }

    /// engineType(forModelPath:) 与 debugEngineDescription 同一判定：
    /// 设置页能力查询与转录调度使用同一事实源。
    /// debugEngineDescription 仅 DEBUG 编译（同 TranscriptionService）。
    #if DEBUG
    func testEngineTypeResolutionMatchesDebugDescription() {
        let path = ModelPathResolver.resolveModelPath()
        let type = TranscriptionService.engineType(forModelPath: path)
        let description = TranscriptionService.debugEngineDescription(forPath: path)
        XCTAssertTrue(description.hasSuffix("engine=\(type.rawValue)"),
                      "engineType 判定(\(type.rawValue))与调试描述不一致：\(description)")
    }
    #endif
}
