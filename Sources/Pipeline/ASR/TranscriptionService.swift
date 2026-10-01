import Foundation

/// 引擎门面（1.4 渐进式重构第一步）：解析当前模型 → 对应 ASRProvider → 委托转录。
///
/// 1.4 中本类直接调用 CWhisper / NemotronEngine / Qwen3ASRBackend；
/// 重构后仅面向 ASRProvider 协议调度，具体推理由各自适配层完成：
///
///   TranscriptionService
///         ↓
///      ASRProvider
///         ↓
///   WhisperProvider 包装 CWhisper（whisper.cpp）
///   NemotronProvider 包装 NemotronEngine（FluidAudio / Core ML）
///   QwenProvider     包装 Qwen3ASRBackend（transcribe.cpp / ggml + Metal）
///
/// 对外 API（transcribe / transcribeChunk / preloadLiveModel /
/// unloadLiveModel / shutdown / 静态查询）与输入输出数据结构保持不变。
final class TranscriptionService: @unchecked Sendable {
    private let whisperProvider = WhisperProvider()
    private let nemotronProvider = NemotronProvider()
    private let qwenProvider = QwenProvider()
    /// 在线 OpenAI 兼容 Whisper API（无本地模型，需在设置中启用并配置）。
    private let onlineProvider = OnlineASRProvider()
    /// 远程自托管端点（局域网 GPU 机器；与在线共用请求栈，独立配置）。
    private let remoteProvider = RemoteASRProvider()
    /// Apple Speech（macOS 26 原生 SpeechAnalyzer / SpeechTranscriber 引擎）。
    private let appleProvider = AppleSpeechManager.shared
    /// FunASR（SenseVoice / Paraformer 系）。
    private let funasrProvider = FunASRProvider()

    /// 实时会话正在使用的引擎（实时循环每轮登记；unloadLiveModel 收尾清零）。
    ///
    /// 为什么是集合而不是单个布尔：此前只有「preload 那一刻是 Nemotron」这一个
    /// 标志位，会话中途切引擎（用户改设置 / 自动降级 / 切实时模型）就不置位 ——
    /// 于是文件转录（APIServer 与实时循环共用本 service）会把它卸掉，实时循环
    /// 下一轮只能重建（数秒静默）；反向也一样：实时会话收尾时无条件卸载
    /// qwen / funasr，会把在途的文件转录打断。
    private let liveStateLock = NSLock()
    private var liveSessionActive = false
    private var liveSessionEngines: Set<ASRProviderEngine> = []
    /// 统一音频分片聚合器（按「音频分片模式」+ 引擎类型决定是否启用）。
    private let chunkManager = ChunkManager()
    /// 流式引擎喂音水位线（tail 重转录重叠去重；见 ASRProvider 声明）。
    /// 生命周期：unloadLiveModel 清零；实时引擎切换清零（会话语义变化）。
    private var streamingWaterline = StreamingFeedWaterline()
    /// 最近一次经水位线裁剪的流式引擎标识（切换即重置水位线）。
    private var streamingWaterlineEngine: ASRProviderEngine? = nil
    /// 最近一次喂音时的 FunASR recognizer 代数（见 FunASRProvider
    /// .recognizerGeneration）：代数变化 = recognizer 已重建，水位线回退。
    private var streamingWaterlineFunASRGeneration: Int? = nil
    private let waterlineLock = NSLock()

    /// Which engine the currently selected model runs on.
    private enum ResolvedEngine {
        case whisper(path: String)
        case nemotron(directory: String)
        case qwen3asr(path: String)
        case online
        case remote
        case apple
        case funasr
    }

    /// Engine resolution: the user's ASR Engine selection takes precedence
    /// (switching takes effect immediately, no restart). `auto` keeps the
    /// 1.4 path-based detection.
    private func resolveEngine() -> ResolvedEngine {
        switch ASREngineSelection.current {
        case .online:
            // 开关未启用时回落自动判定（本地模型）。
            guard OnlineASRConfig.isEnabled else {
                return Self.engine(forPath: ModelPathResolver.resolveModelPath())
            }
            return .online
        case .remote:
            // 端点未配置时回落自动判定（与在线同策略）。
            guard RemoteASRConfig.isConfigured else {
                return Self.engine(forPath: ModelPathResolver.resolveModelPath())
            }
            return .remote
        case .whisper:
            return .whisper(path: ModelPathResolver.resolveModelPath())
        case .qwen:
            return .qwen3asr(path: ModelPathResolver.resolveModelPath())
        case .nemotron:
            return .nemotron(directory: ModelPathResolver.resolveModelPath())
        case .apple:
            return .apple
        case .funasr:
            return .funasr
        case .auto:
            return Self.engine(forPath: ModelPathResolver.resolveModelPath())
        }
    }

    /// Engine for the live-transcription model selection. The user's ASR
    /// 实时引擎解析缓存：实时循环每轮调用 resolveLiveEngine() 3-5 次
    ///（transcribeChunk 入口 / emptyNormalizedResult / liveMergePolicy×2），
    /// auto 档每次走完整 fileExists 链（liveModelFile → catalog → GGUF 头
    /// 探测）——纯主线程磁盘 IO。按解析出的模型路径缓存；路径未变时
    /// 直接复用（引擎选择档变化会改变解析结果，故键含选择档）。
    private var liveEngineCache: (selectionKey: String, modelPath: String, engine: ResolvedEngine)?
    private let liveEngineLock = NSLock()

    /// Engine selection takes precedence; otherwise the live model path
    /// (`liveModelFile`, falling back to the main model) decides, matching 1.4.
    private func resolveLiveEngine() -> ResolvedEngine {
        let selection = ASREngineSelection.current
        // 缓存键含选择档与在线/远程开关（影响回落判定）。
        let selectionKey = "\(selection.rawValue)|\(OnlineASRConfig.isEnabled)|\(RemoteASRConfig.isConfigured)"
        return liveEngineLock.withLock { () -> ResolvedEngine in
            if let cache = liveEngineCache,
               cache.selectionKey == selectionKey {
                let currentPath = ModelPathResolver.resolveLiveModelPath()
                if currentPath == cache.modelPath {
                    return cache.engine
                }
            }
            let engine = resolveLiveEngineUncached(selection)
            liveEngineCache = (selectionKey, ModelPathResolver.resolveLiveModelPath(), engine)
            return engine
        }
    }

    private func resolveLiveEngineUncached(_ selection: ASREngineSelection) -> ResolvedEngine {
        switch selection {
        case .online:
            // 开关未启用时回落自动判定（本地模型）。
            guard OnlineASRConfig.isEnabled else {
                return Self.engine(forPath: ModelPathResolver.resolveLiveModelPath())
            }
            return .online
        case .remote:
            guard RemoteASRConfig.isConfigured else {
                return Self.engine(forPath: ModelPathResolver.resolveLiveModelPath())
            }
            return .remote
        case .whisper:
            return .whisper(path: ModelPathResolver.resolveLiveModelPath())
        case .qwen:
            return .qwen3asr(path: ModelPathResolver.resolveLiveModelPath())
        case .nemotron:
            return .nemotron(directory: ModelPathResolver.resolveLiveModelPath())
        case .apple:
            return .apple
        case .funasr:
            return .funasr
        case .auto:
            return Self.engine(forPath: ModelPathResolver.resolveLiveModelPath())
        }
    }

    private static func engine(forPath path: String) -> ResolvedEngine {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            // 目录模型：catalog 元数据优先，其次目录内容特征（FunASR 文件清单），
            // 两者都不命中才回落 Nemotron。
            // 为什么必须加目录内容判定：目录被改名 / 自定义路径指向 HF 原始
            // 目录名时 catalog 必然未命中，而 ModelCatalog.isComplete 与
            // SherpaONNXRuntime.load 都走 FunASRModelConfig.resolve() —— 三处
            // 对「这是不是 FunASR」必须同一答案，否则 SenseVoice 目录被判成
            // Nemotron，报 metadata.json not found。
            let dirName = (path as NSString).lastPathComponent
            if let catalogModel = ModelCatalog.model(fileName: dirName),
               catalogModel.engine == .funasr {
                return .funasr
            }
            if looksLikeFunASRDirectory(URL(fileURLWithPath: path, isDirectory: true)) {
                return .funasr
            }
            return .nemotron(directory: path)
        }
        // Qwen3-ASR 是单文件 GGUF：按目录中的模型名识别，避免被误当成 whisper 加载。
        let fileName = (path as NSString).lastPathComponent
        if let catalogModel = ModelCatalog.model(fileName: fileName) {
            if catalogModel.engine == .qwen3asr { return .qwen3asr(path: path) }
            if catalogModel.engine == .funasr { return .funasr }
        }
        // 自定义路径/非标准文件名：读取 GGUF 头部 general.architecture 判定。
        if let arch = GGUFInspector.architecture(atPath: path), isQwen3ASRArchitecture(arch) {
            return .qwen3asr(path: path)
        }
        return .whisper(path: path)
    }

    /// 目录内容是否是 FunASR 模型（sherpa-onnx 转换包结构）。
    /// 事实源与 ModelCatalog.isComplete / SherpaONNXRuntime.load 统一走
    /// FunASRModelConfig 的文件角色清单（encoder / adaptor / llm / tokens /
    /// tokenizer 目录），而不是硬编码单个文件名。
    private static func looksLikeFunASRDirectory(_ directory: URL) -> Bool {
        let candidates = [
            FunASRModelConfig.paraformerStreaming,
            FunASRModelConfig.funASRNano,
            FunASRModelConfig.paraformerZH,
            FunASRModelConfig.senseVoiceSmall,
        ]
        return candidates.contains { $0.isComplete(in: directory) }
    }

    /// GGUF 架构值是否是 Qwen3-ASR。
    /// 写法不统一（qwen3_asr / qwen3-asr / Qwen3ASR / qwen3_asr_...），
    /// 去掉大小写与分隔符后按「含 qwen3 且含 asr」判定——此前只匹配两个
    /// 固定字面量，写法不同就回落 whisper，whisper.cpp 加载 GGUF 直接失败。
    private static func isQwen3ASRArchitecture(_ arch: String) -> Bool {
        let normalized = arch.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.contains("qwen3") && normalized.contains("asr")
    }

    func shutdown() {
        unloadLiveModel()
        Task { await whisperProvider.unloadModel() }
        Task { await nemotronProvider.unloadModel() }
        Task { await qwenProvider.unloadModel() }
        Task { await onlineProvider.unloadModel() }
        Task { await remoteProvider.unloadModel() }
        Task { await appleProvider.unloadModel() }
        // FunASR 此前漏在此列表外：900MB 级目录模型（paraformer-zh /
        // fun-asr-nano）在「释放模型」与看门狗自动回收后仍驻留内存，
        // 于是看门狗反复触发却毫无效果。
        Task { await funasrProvider.unloadModel() }
    }

    /// Free the live session's resources when recording ends: the dedicated
    /// live whisper context (if any), and every engine the live session
    /// actually used (recorded per pass — mid-session engine switches
    /// included). Online mode: cancel in-flight requests and drop the pending
    /// audio queue. 公开语义不变：仍然是「结束实时会话、释放它占用的资源」。
    func unloadLiveModel() {
        // 实时会话用过哪些引擎：本次收尾只释放这些（此前无条件卸载
        // qwen / funasr，会把文件转录在途的模型一起卸掉）。
        let used = endLiveSession()

        whisperProvider.unloadLiveModel()
        // whisper 的实时专用 ctx 已由上一行释放；主 ctx 留给文件转录
        //（原有语义：录音结束后紧接着的文件转录不必重载大模型）。
        for engine in used where engine != .whisper {
            unloadProvider(engine)
        }
        onlineProvider.cancelPending()
        // 远程引擎：取消在途请求 + 复位配置活动源（回到在线键）。
        RemoteASRConfig.activateAsActiveSource(false)
        chunkManager.clear()  // 丢弃未发送的聚合残留
        waterlineLock.withLock {
            streamingWaterline.reset()
            streamingWaterlineEngine = nil
            streamingWaterlineFunASRGeneration = nil
        }
    }

    /// 释放某个引擎的常驻资源（实时会话收尾 / 文件转录互斥用）。
    /// 无状态与在线系引擎的 unload 均为幂等空操作，列表统一便于维护。
    private func unloadProvider(_ engine: ASRProviderEngine) {
        switch engine {
        case .whisper: Task { await whisperProvider.unloadModel() }
        case .nemotron: Task { await nemotronProvider.unloadModel() }
        case .qwen3asr: Task { await qwenProvider.unloadModel() }
        case .funasr: Task { await funasrProvider.unloadModel() }
        case .apple: Task { await appleProvider.unloadModel() }
        case .online: onlineProvider.cancelPending()
        case .remote: Task { await remoteProvider.unloadModel() }
        }
    }

    /// 登记「本轮实时会话正在使用该引擎」（实时循环每轮调用，覆盖中途切引擎）。
    private func markLiveSessionEngine(_ engine: ASRProviderEngine) {
        liveStateLock.withLock {
            liveSessionActive = true
            liveSessionEngines.insert(engine)
        }
    }

    /// 实时会话当前是否正在使用该引擎（文件转录路径的卸载互斥判定）。
    private func liveSessionUses(_ engine: ASRProviderEngine) -> Bool {
        liveStateLock.withLock { liveSessionActive && liveSessionEngines.contains(engine) }
    }

    /// 结束实时会话并取回它用过的引擎集合（同时清零标志）。
    private func endLiveSession() -> Set<ASRProviderEngine> {
        liveStateLock.withLock { () -> Set<ASRProviderEngine> in
            let used = liveSessionActive ? liveSessionEngines : Set<ASRProviderEngine>()
            liveSessionActive = false
            liveSessionEngines.removeAll()
            return used
        }
    }

    /// Transcribe (or translate-to-English, when `translate` is true) an audio file.
    /// `language` is an optional ISO-639-1 code; nil/empty means auto-detect.
    /// 显式传入优先；未传时应用设置页「识别语言」的配置（仅对支持手动
    /// 指定的引擎生效——whisper / nemotron / 在线；Apple 用自己的语言包
    /// 设置、Qwen 自动检测，均不受配置影响）。
    ///
    /// 统一识别结果层：出口经 ASRResultNormalizer 归一为 NormalizedASRResult
    /// （多段时间戳保留；fullText 为兼容字段——Provider 原始整段文本）。
    func transcribe(fileURL: URL,
                    language: String? = nil,
                    translate: Bool = false,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> NormalizedASRResult {
        let configuredLanguage = ConfigurationManager.shared.asr.effectiveASRLanguage
        let effectiveLanguage = (language?.isEmpty == false) ? language : configuredLanguage
        // 引擎只解析一次并向下传递：两次 resolveEngine() 之间若 UserDefaults
        // 变更（用户切引擎/切模型），归一结果标注的 engine 会与实际执行的
        // 引擎不一致；且每次解析都做 fileExists + GGUF 头读取（纯磁盘 IO）。
        let engine = resolveEngine()
        let result = try await transcribeFileDispatch(
            engine: engine, fileURL: fileURL, language: language,
            effectiveLanguage: effectiveLanguage ?? "",
            translate: translate, onProgress: onProgress)
        let chunkProvider = provider(for: engine)
        return ASRResultNormalizer.normalize(
            result, engine: chunkProvider.engine,
            metadata: ASRMetadata.default(isStreamingEngine: false))
    }

    /// 文件转录引擎分派（原 transcribe 主体，返回 Provider 原始结果）。
    private func transcribeFileDispatch(engine: ResolvedEngine,
                                        fileURL: URL,
                                        language: String?,
                                        effectiveLanguage: String,
                                        translate: Bool,
                                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        switch engine {
        case .nemotron:
            guard !translate else {
                throw TranscriptionError.processFailed(
                    "Translation to English is not supported by the Nemotron model. Select a Whisper model instead."
                )
            }
            // Free the main whisper ctx (a live session's context stays).
            // 实时会话正在用 whisper 时不释放：实时档与主档同模型时共用主 ctx，
            // 卸掉会让实时循环下一轮重建（数秒静默）。
            if !liveSessionUses(.whisper) {
                Task { await whisperProvider.unloadModel() }
            }
            return try await nemotronProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .qwen3asr:
            return try await qwenProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .whisper:
            // 实时会话正在用 Nemotron 时保留它（原行为）；判定来源改为
            // 「实时循环登记的引擎集合」，覆盖会话中途切到 Nemotron 的情形
            //（此前只在 preload 时置位 → 中途切换后文件转录会把它卸掉）。
            if !liveSessionUses(.nemotron) {
                Task { await nemotronProvider.unloadModel() }
            }
            return try await whisperProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .online:
            guard !translate else {
                throw TranscriptionError.processFailed(
                    "Translation to English is not supported by the Online API. Select a Whisper model instead."
                )
            }
            return try await onlineProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .remote:
            guard !translate else {
                throw TranscriptionError.processFailed(
                    "Translation to English is not supported by Remote ASR. Select a Whisper model instead."
                )
            }
            return try await remoteProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        case .apple:
            guard !translate else {
                throw TranscriptionError.processFailed(
                    "Translation to English is not supported by Apple Speech. Select a Whisper model instead."
                )
            }
            // Apple：language 参数原样透传（不套用「识别语言」配置——
            // Apple 有自己的语言包选择器，空值回落 appleSpeechLocale）。
            return try await appleProvider.transcribeFile(
                fileURL: fileURL, language: language, translate: translate, onProgress: onProgress
            )
        case .funasr:
            return try await funasrProvider.transcribeFile(
                fileURL: fileURL, language: effectiveLanguage, translate: translate, onProgress: onProgress
            )
        }
    }

    // MARK: - Chunk Transcription (Live/Streaming)

    /// Transcribe raw 16kHz mono PCM Float32 samples directly (used for live transcription during recording).
    /// Uses the live model selection (falling back to the main model) and runs on a background queue.
    ///
    /// 统一识别结果层：本方法出口即 NormalizedASRResult（ASRResultNormalizer
    /// 归一），字幕层只消费归一结果、按 metadata.mergePolicy 行为。
    ///
    /// 音频分片（Chunk Manager）：
    /// - 按「音频分片模式」+ 当前引擎类型决定是否聚合：
    ///   关闭 → 直接发送 Provider（原实时流程）；
    ///   仅本地 → 本地引擎聚合、Online 跳过；仅在线 → Online 聚合、本地跳过；
    /// - 聚合未达标（时长 / 等待）时返回空结果，上层循环继续累积；
    /// - `absoluteRange` 是 chunk 在录制时间轴上的绝对采样区间，供流式引擎
    ///   （Apple Speech）做去重水位线；聚合路径会打乱位置 → 透传 nil。
    func transcribeChunk(samples: ArraySlice<Float>,
                         absoluteRange: Range<Int>? = nil) async throws -> NormalizedASRResult {
        guard !samples.isEmpty else {
            return emptyNormalizedResult()
        }

        let engine = resolveLiveEngine()
        // 实时会话登记（覆盖本方法的所有分支：聚合路径 / 直发路径）：
        // 每轮都登记，会话中途切引擎或自动降级都能反映到「实时会话在用谁」。
        markLiveSessionEngine(provider(for: engine).engine)
        if shouldChunk(engine: engine) {
            chunkManager.append(samples)
            guard chunkManager.isReadyToSend() else {
                // 聚合中：标记占位，调度层不得据此发布字幕（否则每个未达标
                // 的 pass 都会用空 tail 清掉屏幕上正在显示的当前句）。
                return aggregationPendingResult()
            }
            let chunk = chunkManager.takeAll()
            return try await dispatchChunk(chunk, engine: engine, absoluteRange: nil)
        }

        // 流式引擎：tail 重转录的重叠区间按绝对水位线裁剪（provider 只收
        // 纯新增采样，见 ASRProvider.isStreamingEngine）。无状态引擎直通。
        let liveProvider = provider(for: engine)
        let samplesToFeed: ArraySlice<Float>
        if await liveProvider.isStreamingEngine {
            // FunASR 流式：recognizer 被卸载重建（语言热切换 / 实时模型切换）时，
            // 已喂入但未出结果的音频随旧 recognizer 一起消失——喂音水位线必须
            // 回退，让该区间重新喂入新 recognizer，否则这段音频永久漏识别。
            let funasrGeneration: Int?
            if liveProvider.engine == .funasr {
                funasrGeneration = await funasrProvider.recognizerGeneration
            } else {
                funasrGeneration = nil
            }
            samplesToFeed = waterlineLock.withLock { () -> ArraySlice<Float> in
                if streamingWaterlineEngine != liveProvider.engine {
                    streamingWaterline.reset()
                    streamingWaterlineEngine = liveProvider.engine
                    streamingWaterlineFunASRGeneration = funasrGeneration
                } else if let funasrGeneration,
                          streamingWaterlineFunASRGeneration != funasrGeneration {
                    streamingWaterline.reset()
                    streamingWaterlineFunASRGeneration = funasrGeneration
                }
                guard let range = absoluteRange else {
                    streamingWaterline.markUntrackedFeed()
                    return samples
                }
                // 只 peek 不提交：喂入可能失败（Apple 未授权/会话错误/
                // 超时），把没送到的音频记成「已喂」会让后续每轮都从它之后
                // 开始 —— 那段音频永久不再转录，字幕静默跳过一截。
                // 成功后在下面 commitFed 推进水位线。
                guard let start = streamingWaterline.peekUnfedStart(in: range) else {
                    return []
                }
                // 零拷贝裁剪：dropFirst 返回借用原存储的切片（P0 链路禁 Array）。
                return samples.dropFirst(start)
            }
            if samplesToFeed.isEmpty {
                // 区间已全部喂过（tail 重转录的重复部分）：同样没有新产出。
                return aggregationPendingResult()
            }
        } else {
            samplesToFeed = samples
        }
        let result = try await dispatchChunk(samplesToFeed, engine: engine,
                                             absoluteRange: absoluteRange)
        // 喂入成功：推进水位线（失败时上面已抛出，水位线保持不动，
        // 下一轮重发同一区间，不丢音频——流式引擎的重复发送由水位线
        // 本身保证只在「上轮没成功」时发生）。
        if await liveProvider.isStreamingEngine, let range = absoluteRange {
            waterlineLock.withLock { streamingWaterline.commitFed(range) }
        }
        return result
    }

    /// 空归一结果（调度层在无音频 / 未达标时收到，仍携带引擎与元数据）。
    private func emptyNormalizedResult() -> NormalizedASRResult {
        let engine = provider(for: resolveLiveEngine()).engine
        return .empty(engine: engine, metadata: ASRMetadata.default(isStreamingEngine: false))
    }

    /// 「本轮无产出、音频仍在聚合/已喂过」占位结果：调度层应跳过字幕发布。
    /// mergePolicy 在此路径不参与显示（结果永远没有 segments），
    /// 关键字段是 isAggregationPending。
    private func aggregationPendingResult() -> NormalizedASRResult {
        let engine = provider(for: resolveLiveEngine()).engine
        return .aggregationPending(
            engine: engine,
            metadata: ASRMetadata.default(isStreamingEngine: false))
    }
    /// 把切片（或原样样本）发送到对应引擎的 Provider，出口统一归一化：
    /// Provider 返回结果经 ASRResultNormalizer 折算（引擎喂音语义
    /// isStreamingEngine → 合并策略元数据），字幕层不再感知引擎差异。
    private func dispatchChunk(_ samples: ArraySlice<Float>,
                               engine: ResolvedEngine,
                               absoluteRange: Range<Int>?) async throws -> NormalizedASRResult {
        let chunkProvider = provider(for: engine)
        let metadata = ASRMetadata.default(isStreamingEngine: await chunkProvider.isStreamingEngine)
        let result = try await chunkProvider.transcribeChunk(
            samples: samples, absoluteRange: absoluteRange)
        // 段级 final 语义（含 isRevision → final 修正）由归一层按
        // mergePolicy 折算，调度层直接消费归一结果，无需在此二次改写。
        return ASRResultNormalizer.normalize(
            result, engine: chunkProvider.engine, metadata: metadata)
    }

    /// 引擎 → provider（水位线路径用；与 dispatchChunk 同一分发表）。
    private func provider(for engine: ResolvedEngine) -> ASRProvider {
        switch engine {
        case .nemotron: return nemotronProvider
        case .qwen3asr: return qwenProvider
        case .whisper: return whisperProvider
        case .online: return onlineProvider
        case .remote: return remoteProvider
        case .apple: return appleProvider
        case .funasr: return funasrProvider
        }
    }

    /// 音频分片判定：按「音频分片模式」+ 引擎类型。
    /// - Online API 恒不参与（句子模式由 Provider 内 OnlineASRBuffer 负责，
    ///   避免双重聚合）；
    /// - Apple Speech 不参与分片（系统流式识别按块直接发送）。
    private func shouldChunk(engine: ResolvedEngine) -> Bool {
        switch AudioChunkingMode.current {
        case .off:
            return false
        case .localOnly:
            switch engine {
            case .whisper, .nemotron, .qwen3asr: return true
            case .online, .remote, .apple, .funasr: return false
            }
        case .onlineOnly:
            switch engine {
            case .online, .remote: return true
            case .apple, .funasr: return false
            case .whisper, .nemotron, .qwen3asr: return false
            }
        }
    }

    /// 实时引擎的字幕合并策略（统一识别结果层）：由 Provider 声明的
    /// isStreamingEngine 折算（Apple Speech 与 FunASR paraformer-streaming
    /// 均为增量引擎——旧实现只认 Apple，paraformer-streaming 被误按
    /// 整段替换处理，当前句每轮被最新碎片覆盖）。这类引擎没有 tail
    /// 重转录的音频 overlap，强制封口后不需要对首字符做 overlap 裁剪。
    var liveMergePolicy: ASRMergePolicy {
        get async {
            await provider(for: resolveLiveEngine()).isStreamingEngine
                ? .appendIncrement : .replaceTail
        }
    }

    /// 实时引擎是否输出「纯增量」分块结果（mergePolicy 的布尔形式，
    /// 供喂音节奏等调度判断使用）。
    var liveEngineStreamsIncrementally: Bool {
        get async { await liveMergePolicy == .appendIncrement }
    }

    /// Ensure the live-transcription model is loaded (pre-loading at recording
    /// start, to avoid model loading latency on the first chunk).
    func preloadLiveModel() async throws {
        // 先登记「本次实时会话在用哪个引擎」再加载：加载失败也要登记，
        // 否则失败残留（部分加载的引擎）在会话收尾时不会被释放。
        let engine = resolveLiveEngine()
        markLiveSessionEngine(provider(for: engine).engine)
        switch engine {
        case .whisper:
            try await whisperProvider.prepare()
        case .nemotron:
            try await nemotronProvider.prepare()
        case .qwen3asr:
            try await qwenProvider.prepare()
        case .funasr:
            try await funasrProvider.prepare()
        case .online:
            // 在线模式：校验配置（失败时由调用方提示，不影响本地引擎）。
            try await onlineProvider.prepare()
        case .remote:
            // 远程端点：校验配置（连通性由首次请求验证）。
            try await remoteProvider.prepare()
        case .apple:
            // Apple Speech：请求授权并启动流式会话（语言资源缺失自动下载）。
            try await appleProvider.prepare()
        }
    }

    // MARK: - Static Queries（UI / API 层继续使用，行为不变）

    /// 当前识别配置对「手动指定识别语言」的支持（设置页 UI 用）。
    enum ASRLanguageSupport {
        /// 可选（whisper / nemotron / 在线）：显示语言选择器。
        case selectable
        /// 自动检测、不可指定（Qwen3-ASR），附说明文字。
        case autoOnly(String)
        /// Apple：按 Apple Speech 语言包设置。
        case appleLocale
    }

    /// 按当前引擎选择（本地按所选模型解析引擎）判定语言选择支持。
    static var languageSupport: ASRLanguageSupport {
        let qwenAuto = ASRLanguageSupport.autoOnly(
            "Qwen3-ASR 自动语种检测（30 种语言 + 22 种中文方言），不支持手动指定。")
        switch ASREngineSelection.current {
        case .apple:
            return .appleLocale
        case .online:
            // 小米 MiMo 仅支持中英（asr_options.language=auto/zh/en）——
            // 语言选择器只列中英 + 自动；其余在线端点全表。
            if OnlineASRApiType.current == .mimo {
                return .autoOnly("小米 MiMo 仅支持中英双语（自动/中文/英文）。")
            }
            return .selectable
        case .remote:
            // 自托管端点：OpenAI Whisper 协议支持 language 参数，全表可选
            //（端点侧是否多语取决于部署的模型）。
            return .selectable
        case .qwen:
            return qwenAuto
        case .funasr:
            // 按所选 FunASR 模型细分：SenseVoice/Nano 支持语言提示
            //（asrLanguage → sense_voice.language hint）；
            // Paraformer 系中英双语内置，无需指定。
            let modelPath = ModelPathResolver.resolveModelPath()
            let funasrType = FunASRModelConfig.config(
                for: URL(fileURLWithPath: modelPath, isDirectory: true)).modelType
            switch funasrType {
            case .paraformerStreaming, .paraformerZH:
                return .autoOnly("Paraformer 中英双语内置，无需指定语言。")
            case .senseVoiceSmall, .funASRNano:
                return .selectable
            }
        case .auto, .whisper, .nemotron:
            if case .qwen3asr = engine(forPath: ModelPathResolver.resolveModelPath()) {
                return qwenAuto
            }
            return .selectable
        }
    }

    static var appSupportModelPath: String {
        ModelPathResolver.appSupportModelPath
    }

    /// Check whether a usable model file exists at any known location.
    static func modelExists() -> Bool {
        if let files = try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path),
           // whisper 模型是 .bin，Qwen3-ASR 等 GGUF 模型是 .gguf。
           files.contains(where: { $0.hasSuffix(".bin") || $0.hasSuffix(".gguf") }) {
            return true
        }
        if ModelCatalog.all.contains(where: { $0.engine == .nemotron && ModelCatalog.isComplete($0) }) {
            return true
        }
        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return true
        }
        if FileManager.default.fileExists(atPath: appSupportModelPath) {
            return true
        }
        let thisFile = #filePath
        let sourcesDir = (thisFile as NSString).deletingLastPathComponent
        let projectRoot = (sourcesDir as NSString).deletingLastPathComponent
        let projectPath = (projectRoot as NSString).appendingPathComponent("Models/ggml-model.bin")
        return FileManager.default.fileExists(atPath: projectPath)
    }

    /// Returns all languages supported by the loaded whisper.cpp library.
    static func availableLanguages() -> [(code: String, name: String)] {
        WhisperProvider.availableLanguages()
    }

#if DEBUG
    /// 调试：打印指定路径的 GGUF 架构与解析出的引擎。
    static func debugEngineDescription(forPath path: String) -> String {
        let arch = GGUFInspector.architecture(atPath: path) ?? "unknown"
        switch engine(forPath: path) {
        case .whisper: return "arch=\(arch) engine=whisper"
        case .nemotron: return "arch=\(arch) engine=nemotron"
        case .qwen3asr: return "arch=\(arch) engine=qwen3asr"
        case .online: return "arch=\(arch) engine=online"
        case .remote: return "arch=\(arch) engine=remote"
        case .apple: return "arch=\(arch) engine=apple"
        case .funasr: return "arch=\(arch) engine=funasr"
        }
    }
#endif

    /// 按模型路径解析引擎标识（能力查询用；与 resolveEngine 的本地档
    /// 同一判定事实源——目录/GGUF 架构/catalog 元数据）。
    static func engineType(forModelPath path: String) -> ASREngineType {
        switch engine(forPath: path) {
        case .whisper: return .whisper
        case .nemotron: return .nemotron
        case .qwen3asr: return .qwen3asr
        case .online: return .online
        case .remote: return .remote
        case .apple: return .apple
        case .funasr: return .funasr
        }
    }
}
