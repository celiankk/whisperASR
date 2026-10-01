import Foundation

// MARK: - FunASR Provider（FunASRProvider）
//
// FunASR 模型（SenseVoice / Paraformer 系）的 ASRProvider 实现——
// 只是新的 Provider，不是独立 ASR 系统：
//
//   ASRManager → TranscriptionService → ASRProvider → FunASRProvider → FunASRRuntime
//
// 音频链路不变：ScreenCaptureKit/Mic → AudioRecorder → VAD → 本 Provider。
// 不自行管理录音；streaming chunk 逻辑沿用 ASRManager 既有循环
//（paraformer-streaming 声明 isStreamingEngine=true 走水位线去重）。
//
// P0 actor 化：原 NSLock + inflightLoad 手工互斥由 actor 隔离取代——
// loadedPath / modelType / in-flight 加载任务都是隔离态，
// 检查-加载-登记在同一执行域内天然原子（挂起点之外的窗口为零）。

actor FunASRProvider: ASRProvider {
    /// 协议要求 `{ get }`：不可变 let（Sendable 类型）天然 nonisolated。
    nonisolated let engine: ASRProviderEngine = .funasr

    /// 当前模型类型：按已解析模型路径从 catalog 元数据推导
    /// （catalog 选 paraformer-zh → .paraformerZH；未知回落 SenseVoice）。
    private var modelType: FunASRModelType = .senseVoiceSmall
    /// 上次加载时的语言提示（语言热切换检测：变化即重载 recognizer——
    /// hint 绑定在 config 构造上，重建即生效，模型加载 ~1-2s 后恢复）。
    private var loadedLangHint: String? = nil

    /// 推理运行时：经注册中心取（sherpa-onnx 后端注册前为占位）。
    private var runtime: FunASRRuntime { FunASRRuntimeRegistry.current() }
    private var loadedPath: String?
    /// 加载互斥（actor 隔离版）：防止实时循环与文件转录并发触发双加载。
    /// 挂起点前同步登记 in-flight 任务，并发调用等待复用同一任务。
    private var inflightLoad: (path: String, task: Task<Void, Never>)?

    /// 识别器代数：每次卸载/重建 recognizer 递增（unloadModel / 语言热切换 /
    /// 实时模型路径切换）。
    ///
    /// 用途（水位线回退入口）：recognizer 换了以后，**已喂入但还没出结果的
    /// 音频随旧 recognizer 一起消失**，而 TranscriptionService 的喂音水位线
    /// 仍记着「这段喂过了」→ 该区间永久漏识别。调度层在流式 FunASR 路径上
    /// 对比本代数，变化即 reset 水位线让该区间重新喂入。
    /// 为什么用代数而不是回调：回调需要在 TranscriptionService 初始化期
    /// 捕获 self（属性初始化顺序不允许），代数只需一次 actor 读。
    private(set) var recognizerGeneration = 0

    /// 流式语义：仅 paraformer-streaming 是流式模型（增量喂音 +
    /// 水位线去重）；SenseVoice / Paraformer-zh / Nano 是整段推理，
    /// 但同样不持有跨块状态——按无状态处理（每轮全量重转录安全）。
    /// 隔离态计算属性：作为协议 `{ get async }` 需求的 witness。
    var isStreamingEngine: Bool { modelType.isStreaming }

    // MARK: - 生命周期

    func prepare() async throws {
        try await loadModelIfNeeded(directory: liveModelDirectory())
    }

    func loadModel() async throws {
        try await loadModelIfNeeded(directory: modelDirectory())
    }

    func unloadModel() async {
        await runtime.unload()
        loadedPath = nil
        inflightLoad = nil
        // recognizer 已销毁：代数递增，调度层据此回退喂音水位线
        //（已喂未出结果的音频不再存在于任何 recognizer 中）。
        recognizerGeneration += 1
    }

    // MARK: - 实时分块

    func transcribeChunk(samples: ArraySlice<Float>) async throws -> TranscriptionResult {
        // 语言热切换：有效提示变化 → 卸载重载（ SenseVoice hint 在
        // recognizer config 上；paraformer 系无语言参数，提示变化无感）。
        let hint = SherpaONNXRuntime.senseVoiceLanguageHint(
            ConfigurationManager.shared.asr.effectiveASRLanguage)
        if hint != loadedLangHint, modelType != .paraformerStreaming {
            await runtime.unload()
            loadedPath = nil
            inflightLoad = nil
            loadedLangHint = hint
            // 热切换重建 recognizer：已喂未出结果的音频随之丢失，
            // 代数递增让调度层把喂音水位线回退（该区间重新喂入）。
            // 注：paraformer-streaming 无语言参数，上面已排除重建。
            recognizerGeneration += 1
            AppLogger.shared.log(.asr, "FunASR language hot-switch → hint=\(hint)")
        }
        try await loadModelIfNeeded(directory: liveModelDirectory())
        // 输入桶化：仅无状态 offline 模型（SenseVoice/paraformer-zh）；
        // 流式模型禁用（补零破坏流语义）。输入零拷贝直传（P0 链路）。
        let input: ArraySlice<Float> = modelType == .paraformerStreaming
            ? samples : InputBucketing.padded(samples)
        let result = try await runtime.transcribe(pcm: input, sampleRate: 16000)
        return result.toTranscriptionResult()
    }

    // MARK: - 文件转录

    func transcribeFile(fileURL: URL,
                        language: String?,
                        translate: Bool,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        guard !translate else {
            throw TranscriptionError.processFailed(
                "Translation to English is not supported by FunASR. Select a Whisper model instead.")
        }
        let samples = try await AudioLoader.loadSamples(url: fileURL)
        try await loadModelIfNeeded(directory: modelDirectory())
        onProgress(0.3)
        let result = try await runtime.transcribe(pcm: samples[...], sampleRate: 16000)
        onProgress(1)
        return result.toTranscriptionResult()
    }

    func status() async -> ASRProviderStatus {
        if loadedPath != nil {
            return .loaded(path: "FunASR（\(modelType.displayName)）")
        }
        return .idle
    }

    // MARK: - 私有

    private func modelDirectory() -> URL {
        URL(fileURLWithPath: ModelPathResolver.resolveModelPath(), isDirectory: true)
    }

    private func liveModelDirectory() -> URL {
        URL(fileURLWithPath: ModelPathResolver.resolveLiveModelPath(), isDirectory: true)
    }

    /// 按需加载（actor 隔离版）：同路径已有在途加载则等待复用；
    /// 路径变化（主/实时模型切换）先卸载旧模型再加载。
    /// 注意 path 是**单 .onnx 文件路径**（ModelCatalog fileName），
    /// 非 isDirectory——sherpa-onnx load(modelPath:) 直接接受模型文件，
    /// tokens 等附属文件按约定放在同目录由后端解析。
    private func loadModelIfNeeded(directory: URL) async throws {
        if loadedPath == directory.path, inflightLoad == nil {
            return
        }
        if let inflight = inflightLoad, inflight.path == directory.path {
            await inflight.task.value
            return
        }

        // 路径变化：推导新模型类型并登记 in-flight 任务（Task 创建与
        // 登记之间无挂起点 → 并发调用必然看到登记，不会双加载）。
        // 占位 runtime 的 load 会抛错——抛错时清掉 in-flight 记录，
        // 让下次重试；成功则记录 loadedPath。
        modelType = Self.modelType(for: directory)
        let task = Task<Void, Never> {
            do {
                await self.runtime.unload()
                // 旧 recognizer 已销毁：代数递增（水位线回退），
                // 否则实时模型切换期间已喂的 tail 音频永久漏识别。
                self.recognizerGeneration += 1
                try await self.runtime.load(modelURL: directory)
                self.loadedPath = directory.path
            } catch {
                self.inflightLoad = nil
            }
        }
        inflightLoad = (directory.path, task)
        await task.value
    }

    /// 模型路径 → 类型：统一走 FunASRModelConfig（目录名 + 文件特征探测），
    /// Provider 不重复维护映射。
    nonisolated static func modelType(for modelURL: URL) -> FunASRModelType {
        FunASRModelConfig.config(for: modelURL).modelType
    }
}
