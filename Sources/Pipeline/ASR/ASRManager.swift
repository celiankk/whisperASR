import Foundation

// MARK: - 识别管理器（ASRManager）
//
// AppState 拆分的一部分：实时识别链路——
// - ASR 启动 / 停止（实时转录循环：静音检测、尾部重转录、封口、去重）；
// - 当前 ASR Provider 管理（经 TranscriptionService 统一分发）；
// - 音频输入 → 识别流程（AudioRecorder 累积缓冲 → transcribeChunk）；
// - 健康检查与自动恢复（每 5 秒资源快照，异常自动清理/重启）；
// - 实时自动保存（live_recovery.json 崩溃恢复）。
//
// UI 状态（liveSegments / liveError / isLiveTranscribing 等）仍由
// AppState 持有（UI 绑定不变），本管理器通过弱引用回写。

final class ASRManager: @unchecked Sendable {
    private let service: TranscriptionService
    private let subtitleManager: SubtitleManager
    private let translationManager: TranslationManager
    /// 弱引用：回写 UI 状态（liveSegments / liveError / toast 等）。
    private weak var appState: AppState?

    /// Maximum chunk duration sent to whisper (30 seconds at 16kHz).
    /// Caps processing time so the loop never snowballs.
    private static let maxChunkSamples = 16000 * 30
    /// When speech runs continuously past this without a pause (8s at 16kHz), force a chunk cut at
    /// the live tail rather than waiting longer. Bounds per-pass re-transcription cost for
    /// continuous/noisy speech（背景音乐或底噪下干净停顿可能整段不出现——8s 上限保证
    /// 每轮重转录成本有界、字幕延迟可控）。Kept well under `maxChunkSamples`.
    private static let forceChunkSamples = 16000 * 8

    /// VAD 单向覆盖上限（帧能量密度）：≥ 该值时启发式的「有语音」证据足够强，
    /// 不采信 Silero VAD 的 false。实测中「高密度 + VAD false」是真实语音被
    /// 判成静音（→ 封口 + trimSamples 释放音频 → 丢语音）的主因；
    /// 低于该值（低/中密度）仍由 VAD 裁决，保留「音乐底噪不被送去识别」的收益。
    private static let vadVetoCeilingDensity: Float = 0.75

    private var liveTranscriptionTask: Task<Void, Never>?
    /// 实时会话代数：每次 startLive 递增，循环退出时用它判断「句柄是不是
    /// 自己那一次的」。为什么需要：循环的退出路径（停录取消 / 引擎异常
    /// break）必须把 liveTranscriptionTask 置 nil——看门狗空闲回收与异常
    /// 重启都要求它为 nil；但置 nil 不能误伤「停录后立刻重录」的新会话。
    private var liveSessionGeneration = 0
    /// 实时识别连续失败计数（成功即清零）；达阈值自动降级到 Apple 引擎。
    private var consecutiveChunkFailures = 0
    /// 连续推理超时计数（≥2 触发上下文重建——进程内回收可能死锁的引擎）。
    private var consecutiveChunkTimeouts = 0
    /// 看门狗（内存超阈值空闲回收；子进程隔离段 1）。
    private let watchdog = ASRWatchdog()
    /// 自适应静音统计：最近 50 次真实停顿（干净封口）的静音时长，
    /// P75×1.2 夹 [0.3, 2.0]s 为停顿判定时长——语速快自动收紧、慢放宽。
    private var silenceDurations: [TimeInterval] = []

    /// 当前生效的停顿判定时长（秒）。
    private var adaptiveSilenceSeconds: TimeInterval {
        Self.adaptiveSilenceSeconds(from: silenceDurations)
    }

    /// 自适应停顿时长（纯函数）：最近停顿时长的 P75×1.2 夹 [0.3, 2.0]s；
    /// 样本 <3 用默认 0.3s。
    static func adaptiveSilenceSeconds(from durations: [TimeInterval]) -> TimeInterval {
        guard durations.count >= 3 else { return 0.3 }
        let sorted = durations.sorted()
        let p75 = sorted[min(sorted.count - 1, sorted.count * 3 / 4)]
        return min(2.0, max(0.3, p75 * 1.2))
    }

    /// 渐进式静音：段越长收口越急（>6s 减半、>10s 四分之一），
    /// 防快语速长段无限膨胀等待自然停顿。
    static func progressiveSilenceFactor(tailSeconds: TimeInterval) -> Double {
        if tailSeconds > 10 { return 0.25 }
        if tailSeconds > 6 { return 0.5 }
        return 1.0
    }

    /// 静音段真实时长（秒）：从 `cut` 逐帧扫到第一个能量高于阈值的帧
    ///（语音重新出现）或段尾（停顿仍在进行 → 返回当前下界）。
    /// 逐帧走 `recorder.rmsEnergy`（零拷贝，不构造整段 Array），且只在干净
    /// 封口时调用（每句一次，不是每轮），开销可忽略。
    static func silenceDuration(after cut: Int,
                                upTo totalSamples: Int,
                                frameSamples: Int,
                                threshold: Float,
                                recorder: AudioRecorder) -> TimeInterval {
        guard frameSamples > 0, cut < totalSamples else { return 0 }
        var offset = cut
        while offset + frameSamples <= totalSamples {
            if recorder.rmsEnergy(from: offset, count: frameSamples) > threshold {
                return Double(offset - cut) / 16000.0
            }
            offset += frameSamples
        }
        return Double(totalSamples - cut) / 16000.0
    }
    /// 本次会话是否已自动降级过（只降一次，避免循环降级）。
    private var hasAutoDegraded = false
    /// 每 5 秒一次的健康检查任务（资源快照 + 自动恢复）。
    private var healthCheckTask: Task<Void, Never>?
    /// 当前录制使用的音频源（自动恢复重启 ASR 会话时使用）。
    private weak var liveRecorder: AudioRecorder?
    private var lastAutoSaveTime: Date = .distantPast

    init(service: TranscriptionService, subtitleManager: SubtitleManager, translationManager: TranslationManager) {
        self.service = service
        self.subtitleManager = subtitleManager
        self.translationManager = translationManager
    }

    /// 注入 AppState（AppRuntimeManager.attach 时调用；弱引用避免循环）。
    func attach(appState: AppState) {
        self.appState = appState
    }

    // MARK: - 实时转录

    /// Start periodic live transcription from the AudioRecorder's accumulated PCM buffer.
    func startLive(recorder: AudioRecorder) {
        // 会话级计数器复位：此前跨会话残留（上一场录制的失败/超时/停顿时长
        // 统计被带入新会话），且 hasAutoDegraded 永不复位 → "每会话只降级一次"
        // 实际退化为"每次启动只降级一次"，后续会话再连败也不会自动降级。
        consecutiveChunkFailures = 0
        consecutiveChunkTimeouts = 0
        hasAutoDegraded = false
        silenceDurations.removeAll()
        appState?.liveSegments = []
        appState?.liveError = nil
        appState?.liveTranslationError = nil
        appState?.liveTranslationPaused = false
        appState?.isLiveTranscribing = true
        translationManager.resetForStop()
        subtitleManager.start()
        SubtitleHistoryManager.shared.clear()
        liveRecorder = recorder
        SherpaVAD.shared.reset()   // 新会话：丢弃上一段的 VAD 内部缓冲
        startHealthCheck()
        // ASR Prompt（热词）：启动识别时生成/刷新（不每句话调用）。
        ASRPromptManager.shared.refresh()
        AppLogger.shared.log(.asr, "Live transcription started")

        liveSessionGeneration += 1
        let generation = liveSessionGeneration
        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }

            // Pre-load the model and wait for it — avoids model loading latency on first chunk.
            // Surface load failures so the user isn't stuck at a silent "Waiting for audio...".
            do {
                try await self.service.preloadLiveModel()
                // 看门狗基线：加载完成即记常驻水位（相对制泄漏检测）。
                await MainActor.run { self.watchdog.recordBaseline() }
            } catch {
                ErrorManager.shared.report(
                    .model, error,
                    context: "preloadLiveModel",
                    userFacing: "Couldn't load transcription model: \(error.localizedDescription)"
                )
                await MainActor.run {
                    self.appState?.liveError = "Couldn't load transcription model: \(error.localizedDescription)"
                    self.appState?.isLiveTranscribing = false
                    // 必须清掉任务句柄：看门狗的「空闲回收」与异常重启都要求
                    // liveTranscriptionTask == nil（见 performHealthCheck /
                    // recoverFromAnomaly）。不清的话一次模型加载失败会让本次
                    // 进程生命周期内**永远不会**再触发内存回收。
                    self.finishLiveLoop(generation: generation)
                }
                self.subtitleManager.stop()
                return
            }
            guard !Task.isCancelled else {
                await MainActor.run { self.finishLiveLoop(generation: generation) }
                return
            }

            // Partial/final streaming model:
            //  - Every pass re-transcribes the unsealed *tail* and shows it immediately, so the
            //    in-progress sentence appears within ~1s (no waiting for a pause).
            //  - Segments before the last silence pause are *sealed* (final) — they stop changing
            //    and are never re-transcribed, which keeps boundaries clean and translation steady.
            var consecutiveSilenceCount = 0
            var lastTranscribedTotal = 0
            // Silence-scan tuning (16kHz): 100ms frames.
            let frameSamples = 1600
            // 固定下限阈值：干净麦克风输入（底噪 RMS < 0.001）行为与之前一致。
            let baseSilenceThreshold: Float = 0.001
            let contextSamples = 16000   // 1s left-context, used only after a forced seal

            while !Task.isCancelled {
                // 每轮 pass 顶部快照引擎流式特性（支持中途自动降级生效，且避免单轮内重复解析配置）
                let streamingEngine = await self.service.liveEngineStreamsIncrementally
                let minTailSamples = streamingEngine ? 16000 / 5 : 8000      // 0.2s vs 0.5s
                let minNewSamples = streamingEngine ? 16000 / 10 : 4800     // 0.1s vs 0.3s

                let totalSamples = recorder.accumulatedSampleCount
                let tailCount = totalSamples - self.subtitleManager.sealedSampleCount

                // Need enough unsealed audio and enough new audio since the last pass —
                // keeps the live tail fresh without re-transcribing identical audio in a tight loop.
                guard tailCount >= minTailSamples, totalSamples - lastTranscribedTotal >= minNewSamples else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                // 自适应静音阈值：固定 0.001 对带底噪/背景音的音频（屏幕共享、视频）
                // 永远不触发干净停顿——最安静帧 RMS 都高于它，封口逻辑失效，
                // 每轮被迫重转录 12s 尾部 → 识别越来越慢。
                // 每轮按最近 10s 的噪声底（帧 RMS 10 分位）动态计算：
                //   跳过阈值 = 噪声底 ×1.2（只有真正的背景静默才跳过转录）；
                //   封口阈值 = 噪声底 ×2.0（停顿帧略高于底噪即可判定）。
                // 干净输入下噪声底 ≈0 → 两个阈值都回落到 0.001，行为不变。
                let noiseFloor = recorder.estimateNoiseFloor(
                    upTo: totalSamples, frameSamples: frameSamples, windowSamples: 16000 * 10)
                let skipThreshold = noiseFloor > 0
                    ? min(max(noiseFloor * 1.2, baseSilenceThreshold), 0.01)
                    : baseSilenceThreshold
                let sealSilenceThreshold = noiseFloor > 0
                    ? min(max(noiseFloor * 2.0, baseSilenceThreshold), 0.02)
                    : baseSilenceThreshold

                // If the whole unsealed tail is silence, seal forward and show only sealed text.
                // 密度噪声门：非全静但语音密度 <25% 的段（音乐底噪/碎音）
                // 不送 ASR——当静音处理，封口跳过省算力。
                let tailSeconds = Double(tailCount) / 16000.0
                var density = recorder.speechDensity(
                    from: self.subtitleManager.sealedSampleCount, to: totalSamples,
                    frameSamples: frameSamples, threshold: skipThreshold)
                let rms = recorder.rmsEnergy(from: self.subtitleManager.sealedSampleCount, count: tailCount)
                // Silero 增强（模型可用时）：能量门判为静音的段再经神经网络
                // 人声确认——音乐底噪 RMS 高于 skipThreshold 时启发式会放行，
                // 人声概率低则同样按静音封口；不可用（nil）时行为不变。
                //
                // 同一轮只喂一次并复用判定：密度门与能量门此前各调一次
                // detectSpeech，第二次必然命中 SherpaVAD 的「区间已全部喂过」
                // 分支并 Flush+Clear——白白重置检测器内部状态（实时语音态与
                // 段队列语义漂移），且多一次锁与判定开销。
                let neuralSpeech: Bool? =
                    (tailSeconds > 1.0 && density >= 0.25) || rms <= skipThreshold
                    ? SherpaVAD.shared.detectSpeech(
                        recorder.getSamples(from: self.subtitleManager.sealedSampleCount,
                                            upTo: totalSamples),
                        absoluteStart: self.subtitleManager.sealedSampleCount)
                    : nil
                if density >= 0.25, tailSeconds > 1.0, let neuralSpeech {
                    // 单向覆盖修正：VAD 的 false 只否决「中等密度」的启发式
                    // 证据，高密度时不直接判静音——原实现无条件 density = 0，
                    // 会把帧能量证据充分的真实语音判成静音 → 封口并
                    // trimSamples 释放音频 → 丢语音（不可恢复）。
                    // 低/中密度仍由 VAD 裁决，保留「音乐底噪不被送去识别」的收益。
                    if neuralSpeech {
                        density = max(density, 1.0)
                    } else if density < Self.vadVetoCeilingDensity {
                        density = 0.0
                    }
                }
                if density < 0.25, tailSeconds > 1.0 {
                    self.subtitleManager.sealSilence(upToSampleCount: totalSamples)
                    lastTranscribedTotal = totalSamples
                    recorder.trimSamples(upTo: max(0, self.subtitleManager.sealedSampleCount - contextSamples))
                    consecutiveSilenceCount += 1
                    let snapshot = self.subtitleManager.sealedSegments
                    await MainActor.run {
                        self.appState?.liveSegments = Array(snapshot.suffix(SubtitleManager.maxLiveSegments))
                        self.throttledAutoSave()
                    }
                    try? await Task.sleep(for: .milliseconds(consecutiveSilenceCount >= 2 ? 1000 : 500))
                    continue
                }

                if rms <= skipThreshold, neuralSpeech != true {
                    self.subtitleManager.sealSilence(upToSampleCount: totalSamples)
                    lastTranscribedTotal = totalSamples
                    recorder.trimSamples(upTo: max(0, self.subtitleManager.sealedSampleCount - contextSamples))
                    consecutiveSilenceCount += 1
                    let snapshot = self.subtitleManager.sealedSegments
                    await MainActor.run {
                        self.appState?.liveSegments = Array(snapshot.suffix(SubtitleManager.maxLiveSegments))
                        self.throttledAutoSave()
                    }
                    try? await Task.sleep(for: .milliseconds(consecutiveSilenceCount >= 2 ? 1000 : 500))
                    continue
                }
                consecutiveSilenceCount = 0

                // Re-transcribe the unsealed tail for live display. After a clean (silence) seal the
                // boundary needs no overlap; after a forced seal, re-transcribe 1s of context and
                // dedup so the cut word isn't dropped. Streaming engines (Apple) only ever return
                // brand-new text — their audio is never re-fed — so no overlap trimming applies.
                let useOverlap = !self.subtitleManager.sealedClean && !streamingEngine
                var tailStart = useOverlap
                    ? max(0, self.subtitleManager.sealedSampleCount - contextSamples)
                    : self.subtitleManager.sealedSampleCount

                // Defensive: bound the tail to whisper's 30s window. Only reachable if a pass
                // stalled badly; surface it instead of silently mis-transcribing.
                if totalSamples - tailStart > Self.maxChunkSamples {
                    print("[Recognition] live tail \(totalSamples - tailStart) samples exceeds maxChunkSamples — transcribing only the most recent (older audio skipped)")
                    await MainActor.run {
                        self.appState?.liveError = "Transcription is falling behind — some audio may be skipped."
                    }
                    tailStart = totalSamples - Self.maxChunkSamples
                }

                let chunk = recorder.getSamples(from: tailStart, upTo: totalSamples)
                print("[Audio] chunk generated size=\(chunk.count) duration=\(String(format: "%.2f", Double(chunk.count) / 16000.0))s tailStart=\(tailStart)")
                guard !chunk.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                lastTranscribedTotal = totalSamples
                let timeOffset = Double(tailStart) / 16000.0
                let absoluteTailStart = tailStart  // let 绑定：@Sendable 闭包不可捕获 var

                // Cap the wait so a GPU/Metal hang doesn't deadlock the live loop.
                // Generous: 4× chunk duration, minimum 60s.
                let chunkSeconds = Double(chunk.count) / 16000.0
                let timeoutSeconds = max(60.0, chunkSeconds * 4.0)
                do {
                    print("[ASR] request start chunk=\(chunk.count)")
                    // 延迟仪表盘：量本 chunk 的引擎推理耗时。
                    // （端到端/翻译往返由 SubtitleLatencyManager 在字幕层插桩，
                    //   此处不重复记 —— 同一指标两个定义会互相污染均值。）
                    let inferenceStart = Date()
                    let result = try await Self.withTimeout(seconds: timeoutSeconds) {
                        try await self.service.transcribeChunk(samples: chunk,
                                                               absoluteRange: absoluteTailStart..<totalSamples)
                    }
                    PipelineLatencyStore.shared.recordASR(
                        ms: Date().timeIntervalSince(inferenceStart) * 1000)
                    consecutiveChunkFailures = 0
                    consecutiveChunkTimeouts = 0
                    // 聚合中无产出：不发布字幕（空 tail 的 .replaceTail 提交
                    // 会清掉屏幕上的当前句）。音频已在缓冲，下轮继续。
                    guard !result.isAggregationPending else {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    // 取消检查：stopLive() 只 cancel() 不 await——本循环可能在
                    // await 期间被取消，若继续走 handleASRResult，会在
                    // finishRecording 已清空 liveSegments / 删除恢复快照之后
                    // 把迟到结果重新推上去（字幕"诈尸"）并重建
                    // live_recovery.json（下次启动提示恢复一段已结束的录音）。
                    guard !Task.isCancelled else { break }
                    // 结果处理收口（partial 合并 / 封口推进 / 快照推送），
                    // 音频循环只负责采集与 chunk 调度。
                    await self.handleASRResult(
                        result,
                        recorder: recorder,
                        context: HandleContext(
                            totalSamples: totalSamples, tailCount: tailCount,
                            tailStart: tailStart, tailSeconds: tailSeconds,
                            useOverlap: useOverlap, timeOffset: timeOffset,
                            frameSamples: frameSamples, contextSamples: contextSamples,
                            adaptiveSilenceSeconds: adaptiveSilenceSeconds,
                            sealSilenceThreshold: sealSilenceThreshold))
                } catch is TimeoutError {
                    ErrorManager.shared.report(
                        .asr, context: "chunk timed out after \(timeoutSeconds)s"
                    )
                    // 看门狗-超时重建：连续 2 次超时 = 上下文可能死锁/损坏，
                    // 卸载实时模型（下轮 pass 懒加载重建——进程内回收）。
                    //
                    // 限制（不要声称"已重建"）：unloadLiveModel 只是把卸载排到
                    // provider actor 的队列尾部，而卡住的推理正占着该 actor
                    //（whisper_full / sherpa 推理不检查取消）——卸载要等它返回
                    // 后才真正执行，之后的下一次 pass 才重建模型。故本轮及
                    // 后续若干轮仍可能继续超时。不做强制中断推理：那会破坏
                    // 引擎内部状态（比多等几轮更糟）。
                    self.consecutiveChunkTimeouts += 1
                    if self.consecutiveChunkTimeouts >= 2 {
                        self.consecutiveChunkTimeouts = 0
                        self.service.unloadLiveModel()
                        AppLogger.shared.log(.asr,
                            "Watchdog: 2 consecutive timeouts — live model unload queued (takes effect after the in-flight inference returns)")
                    }
                    await MainActor.run {
                        self.appState?.liveError = "Transcription is slow — the model or GPU may be stuck. Continuing with next chunk."
                    }
                } catch is CancellationError {
                    // 停录/退出取消：不是引擎故障，不计失败。
                    break
                } catch {
                    ErrorManager.shared.report(.asr, error, context: "live transcription chunk")
                    await Self.handleChunkFailure(appState: self.appState,
                                                  counter: &self.consecutiveChunkFailures,
                                                  hasDegraded: &self.hasAutoDegraded)
                }

                try? await Task.sleep(for: .milliseconds(250))
            }

            // 循环退出（取消 / 停录 / 引擎异常 break）：统一清任务句柄。
            // 此前 break 路径不清句柄 → liveTranscriptionTask 永远非 nil，
            // 看门狗「空闲回收」与「异常重启」两条恢复路径同时永久失效。
            await MainActor.run { self.finishLiveLoop(generation: generation) }
        }
    }

    /// 循环退出收口：只清「自己那一次」的任务句柄（代数守卫，避免清掉
    /// 停录后立刻重录的新会话刚装上的句柄）。
    @MainActor
    private func finishLiveLoop(generation: Int) {
        guard generation == liveSessionGeneration else { return }
        liveTranscriptionTask = nil
    }

    // MARK: - 实时结果处理（handleASRResult）

    /// handleASRResult 的本轮循环上下文（音频坐标与 VAD 阈值快照，
    /// 由调用方从循环变量打包，方法本身不触碰采集调度）。
    struct HandleContext {
        let totalSamples: Int
        let tailCount: Int
        let tailStart: Int
        let tailSeconds: Double
        let useOverlap: Bool
        let timeOffset: Double
        let frameSamples: Int
        let contextSamples: Int
        let adaptiveSilenceSeconds: Double
        let sealSilenceThreshold: Float
    }

    /// 单轮识别结果的完整处理收口：日志 → 时间戳偏移 → 字幕合并
    /// （按归一结果 mergePolicy）→ 封口推进（自适应静音 / 谷值回溯 /
    /// 强制封口）→ 显示快照推送。行为与抽离前逐行一致。
    private func handleASRResult(_ normalized: NormalizedASRResult,
                                 recorder: AudioRecorder,
                                 context: HandleContext) async {
        let asrText = normalized.segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("[ASR] response received text=\(asrText.debugDescription) segments=\(normalized.segments.count) isFinal=\(normalized.segments.first?.isFinal ?? false) language=\(normalized.language ?? "nil")"
            + (asrText.isEmpty ? " REASON=empty-or-still-aggregating" : ""))

        // Offset timestamps to match position in the full stream.
        let tailSegments = normalized.segments.map { seg in
            TranscriptionSegment(
                start: seg.startTime + context.timeOffset,
                end: seg.endTime.map { $0 + context.timeOffset },
                text: seg.text
            )
        }

        // Combine sealed (final) + freshly transcribed tail (interim) for display.
        // 合并策略来自归一结果 metadata（appendIncrement：本轮增量并入
        // pendingTail 累积为完整当前句；replaceTail：整段替换）。
        //
        // final 修正（增量引擎）：归一结果里出现 isFinal 段 = 本轮文本改写了
        // 此前已显示的内容（Apple 把已显示的 "ta pop" 修正为 "pop"）。
        // appendIncrement 只加不减，直接追加会得到 "ta pop pop"；必须回滚
        // 当前未封口 tail 并以 final 段重建，后续封口逻辑用重建后的快照。
        // 同一结果里既有 final 又有非 final 段时，只对最后一个 final 段回滚
        //（它覆盖到的时间区间最大）。
        let revisionSegment = normalized.metadata.mergePolicy == .appendIncrement
            ? normalized.segments.last(where: { $0.isFinal })
            : nil
        let combined: [TranscriptionSegment]
        if let revision = revisionSegment {
            // 段的时间戳同样要加 chunk 偏移（与 tailSegments 一致）。
            combined = subtitleManager.rollbackTail(to: NormalizedSegment(
                id: revision.id,
                text: revision.text,
                startTime: revision.startTime + context.timeOffset,
                endTime: revision.endTime.map { $0 + context.timeOffset },
                confidence: revision.confidence,
                isFinal: true))
        } else {
            combined = subtitleManager.appendTail(
                tailSegments: tailSegments,
                tailStartTime: Double(context.tailStart) / 16000.0,
                useOverlap: context.useOverlap,
                mergePolicy: normalized.metadata.mergePolicy
            )
        }

        // Advance the seal: to a trailing pause (clean), or forced once the tail has
        // grown past the cap without one. Everything before it becomes final.
        // 动态停顿判定：自适应值（P75 统计）× 渐进系数（**当前句**长度）。
        // 渐进系数此前传的是整个未封口 tail 长度（含封口边界之后的全部音频），
        // 长尾时系数提前收紧 → 过早封口；当前句长度从 pendingTail 起点算起
        //（无 tail 文本时回落封口边界）。
        let sentenceStartSeconds = subtitleManager.pendingTailSegments.first?.start
            ?? Double(subtitleManager.sealedSampleCount) / 16000.0
        let sentenceSeconds = max(0, Double(context.totalSamples) / 16000.0 - sentenceStartSeconds)
        let effectiveSilenceSeconds = context.adaptiveSilenceSeconds
            * Self.progressiveSilenceFactor(tailSeconds: sentenceSeconds)
        let dynamicMinSilenceFrames = max(
            1, Int(effectiveSilenceSeconds / (Double(context.frameSamples) / 16000.0)))
        let silenceCut = recorder.lastSilenceCut(
            searchFrom: subtitleManager.sealedSampleCount, searchTo: context.totalSamples,
            frameSamples: context.frameSamples, silenceThreshold: context.sealSilenceThreshold,
            minSilenceFrames: dynamicMinSilenceFrames)
        var newSeal = subtitleManager.sealedSampleCount
        var newSealClean = subtitleManager.sealedClean
        if let cut = silenceCut, cut - subtitleManager.sealedSampleCount >= 1600 {
            newSeal = cut; newSealClean = true
            // 自适应统计样本 = **真实静音时长**（cut → 下一个语音起点/段尾）。
            // 为什么不是 totalSamples - cut：后者把 cut 之后仍在说话的内容也
            // 算成「停顿」，其值随轮询节奏变化 → P75 系统性抬高 → 封口越来越迟。
            silenceDurations.append(Self.silenceDuration(
                after: cut, upTo: context.totalSamples,
                frameSamples: context.frameSamples,
                threshold: context.sealSilenceThreshold,
                recorder: recorder))
            if silenceDurations.count > 50 { silenceDurations.removeFirst() }
        } else if context.tailCount >= Self.forceChunkSamples {
            // 谷值回溯：8s 上限不硬切——后 70% 找平滑能量谷
            //（谷值 < 段均值 80% = 自然停顿），无谷值才硬切。
            if let valley = recorder.lowestEnergyCut(
                searchFrom: subtitleManager.sealedSampleCount,
                searchTo: context.totalSamples, frameSamples: context.frameSamples),
               valley - subtitleManager.sealedSampleCount >= 16000 {
                newSeal = valley; newSealClean = true
            } else {
                newSeal = context.totalSamples; newSealClean = false
            }
        }

        if newSeal > subtitleManager.sealedSampleCount {
            subtitleManager.seal(
                upToSampleCount: newSeal, clean: newSealClean, combined: combined)
            // Nothing behind a clean (silence) seal is needed again; keep 1s behind a
            // forced seal for the next pass's overlap.
            recorder.trimSamples(upTo: max(0, newSeal - (newSealClean ? 0 : context.contextSamples)))
        }

        let snapshot = subtitleManager.snapshot(combined)
        await MainActor.run {
            appState?.liveSegments = snapshot
            print("[Subtitle Input] liveSegments count=\(snapshot.count) last=\(snapshot.last?.text.debugDescription ?? "nil")")
            throttledAutoSave()
        }
        // 翻译不再按每个快照触发：由字幕层检测到“一句结束”后，
        // 通过 translateSentence 整句单飞发送（见 Live Translation）。
    }

    /// 连续失败降级：连续 5 次 chunk 错误且未降级过 → 探测 Apple 引擎
    /// 可用性（prepare：授权 + 语言资源），**成功才切换**并 toast；
    /// 探测失败（如语音识别未授权）不切，toast 指引用户修复——
    /// 切到不可用引擎等于没救（实测事故：在线失败 → 降级 Apple →
    /// Apple 未授权 → 继续死循环）。
    /// 只探测一次（用户处理权限/手动切回后不再干预），避免风暴。
    private static func handleChunkFailure(appState: AppState?,
                                           counter: inout Int,
                                           hasDegraded: inout Bool) async {
        counter += 1
        guard counter >= 5, !hasDegraded else { return }
        let current = ASREngineSelection.current
        guard current != .apple else { return }
        hasDegraded = true
        counter = 0

        // 目标引擎可用性探测：prepare 抛错（未授权/语言不支持/系统版本）
        // 则保持原引擎 + 指路 toast。
        do {
            try await AppleSpeechManager.shared.prepare()
            // 代数守卫：prepare 是异步慢操作（授权/模型加载），期间用户
            // 可能已手动切换引擎——快照对比，不再等则放弃降级写入
            //（避免迟到的自动降级覆盖用户刚做的选择）。
            guard ASREngineSelection.current == current else {
                AppLogger.shared.log(.asr,
                    "Auto-degrade aborted: engine changed during probe (was \(current.rawValue))")
                return
            }
        } catch {
            AppLogger.shared.log(.asr,
                "Auto-degrade probe failed: \(error.localizedDescription) — staying on \(current.rawValue)")
            await MainActor.run {
                appState?.showToast("识别连续失败；Apple 引擎不可用（\(error.localizedDescription)）。请在设置修复或更换引擎。")
            }
            return
        }

        UserDefaults.standard.set(ASREngineSelection.apple.rawValue, forKey: ASREngineSelection.key)
        // prepare 已把 Apple 会话拉起，同步状态防 status 显示漂移。
        await MainActor.run {
            appState?.showToast("识别连续失败，已自动切换到 Apple 引擎（可在设置改回）")
        }
        AppLogger.shared.log(.asr, "Auto-degraded to Apple engine after 5 consecutive chunk failures (was \(current.rawValue))")
    }

    /// Stop the live transcription timer. Called when recording ends.
    func stopLive() {
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        // Free the dedicated live model (if one was loaded) — the final file
        // transcription uses the main model.
        service.unloadLiveModel()
        translationManager.resetForStop()
        healthCheckTask?.cancel()
        healthCheckTask = nil
        liveRecorder = nil
        subtitleManager.stop()
        appState?.isLiveTranscribing = false
        appState?.liveError = nil
        appState?.liveTranslationError = nil
        // Clear live results (the final file transcription will replace them)
        appState?.liveSegments = []
        appState?.liveTranslatedSegments = []
        appState?.liveTranslationPaused = false
        removeLiveRecoveryFile()
        AppLogger.shared.log(.asr, "Live transcription stopped")
    }

    // MARK: - 健康检查与自动恢复

    /// 每 5 秒一次：资源快照；发现异常（内存持续增长/队列过长）自动恢复。
    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.appState?.isLiveTranscribing == true else { return }
                self.performHealthCheck()
            }
        }
    }

    @MainActor
    private func performHealthCheck() {
        guard let appState else { return }
        // 屏幕共享/捕获源被关闭：自动结束录制并释放全部资源。
        if let recorder = liveRecorder,
           recorder.state == .recording,
           !recorder.isCaptureSourceRunning() {
            subtitleManager.engine.logger.log("Capture source stopped — auto ending recording")
            Task { await appState.finishRecording(recorder: recorder) }
            return
        }

        // 看门狗-内存回收：全部空闲（无录制、无转录队列）且常驻内存超
        // 阈值时释放全部模型（下次使用懒加载回来，用户无感）。
        if watchdog.checkIdleReclaim(
            asrIdle: !(liveTranscriptionTask != nil || appState.isLiveTranscribing),
            transcriptionIdle: !appState.isTranscribing) {
            service.shutdown()
            appState.showToast("内存占用过高，已自动释放模型（下次使用自动加载）")
        }

        let model = ModelManager.shared.liveFileName.isEmpty
            ? ModelManager.shared.selectedFileName
            : ModelManager.shared.liveFileName
        let anomaly = subtitleManager.engine.tick(
            asr: liveTranscriptionTask == nil ? 0 : 1,
            translationQueue: translationManager.sentenceTranslationPending,
            subtitleBuffers: appState.liveSegments.count + appState.liveTranslatedSegments.count,
            model: model.isEmpty ? "none" : model
        )
        if anomaly {
            recoverFromAnomaly()
        }
    }

    /// 自动恢复：清理字幕缓存、取消旧任务、必要时重启 ASR 循环；不崩溃。
    @MainActor
    private func recoverFromAnomaly() {
        guard let appState else { return }
        subtitleManager.engine.logger.log("Auto-recovery: cleaning caches and stale tasks")
        translationManager.clearFailureCount()

        // 收紧环形窗口（正常路径已按上限裁剪，这里兜底）。
        appState.liveSegments = subtitleManager.trimDisplayCache(appState.liveSegments)
        appState.liveTranslatedSegments = Array(appState.liveTranslatedSegments.suffix(SubtitleManager.maxLiveSegments))

        // ASR 循环意外死亡时重启一次（由 isLiveTranscribing + 任务存在性保护，避免递归）。
        if liveTranscriptionTask == nil, appState.isLiveTranscribing, let recorder = liveRecorder {
            subtitleManager.engine.logger.log("Auto-recovery: restarting ASR session")
            // 重启不得丢已显示字幕：startLive 会清空字幕缓存（sealedSampleCount
            // 归零）与自适应停顿统计，导致屏幕上的字幕消失 + 整场录音从头
            // 重转录。先快照「已封口段 + 当前未封口 tail + 封口边界 + 封口
            // 洁净度 + 停顿统计」，重启后按 seal() 还原（seal 是唯一能同时
            // 还原段与边界边界的公开入口），新循环从当前采样数继续。
            let preserved = LiveSessionSnapshot(
                segments: subtitleManager.sealedSegments + subtitleManager.pendingTailSegments,
                sealedSampleCount: subtitleManager.sealedSampleCount,
                sealedClean: subtitleManager.sealedClean,
                silenceDurations: silenceDurations)
            startLive(recorder: recorder)
            restoreLiveSession(preserved)
        }
        appState.showToast("检测到资源异常，已自动清理并继续运行")
    }

    /// 异常重启时保留的会话快照（字幕 + 封口边界 + 自适应统计）。
    private struct LiveSessionSnapshot {
        let segments: [TranscriptionSegment]
        let sealedSampleCount: Int
        let sealedClean: Bool
        let silenceDurations: [TimeInterval]
    }

    /// 把异常重启前的会话状态还原回字幕层（startLive 已清空缓存）。
    /// 用 `seal(upToSampleCount:clean:combined:)` 还原：它同时恢复段列表
    /// 与封口边界（boundary 之前的段回到 sealed、之后的留作 pendingTail）。
    private func restoreLiveSession(_ snapshot: LiveSessionSnapshot) {
        guard snapshot.sealedSampleCount > 0 || !snapshot.segments.isEmpty else { return }
        subtitleManager.seal(
            upToSampleCount: snapshot.sealedSampleCount,
            clean: snapshot.sealedClean,
            combined: snapshot.segments)
        silenceDurations = snapshot.silenceDurations
        // 立即回填 UI 显示快照（否则要等下一轮识别完成，屏幕空白约一秒）。
        appState?.liveSegments = subtitleManager.snapshot(snapshot.segments)
        AppLogger.shared.log(.asr,
            "Auto-recovery: restored \(snapshot.segments.count) subtitle segments, sealedSampleCount=\(snapshot.sealedSampleCount)")
    }

    // MARK: - Live Transcription Auto-Save (crash recovery)

    private static var liveRecoveryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("live_recovery.json")
    }

    private struct LiveRecoveryData: Codable {
        let segments: [TranscriptionSegment]
        let fullText: String
        let translatedSegments: [String]
        let translationLanguage: String?
        let savedAt: Date
    }

    /// 是否有可恢复的实时转录快照（AppState 恢复入口读取）。
    static var hasLiveRecoveryData: Bool {
        FileManager.default.fileExists(atPath: liveRecoveryURL.path)
    }

    /// 读取崩溃恢复快照（AppState.importRecoveredTranscription 使用）。
    static func loadRecoveredSnapshot() -> RecoveredSnapshot? {
        guard let data = try? Data(contentsOf: liveRecoveryURL),
              let recovery = try? JSONDecoder().decode(LiveRecoveryData.self, from: data) else {
            return nil
        }
        return RecoveredSnapshot(
            segments: recovery.segments,
            fullText: recovery.fullText,
            translatedSegments: recovery.translatedSegments,
            translationLanguage: recovery.translationLanguage,
            savedAt: recovery.savedAt
        )
    }

    /// 删除崩溃恢复快照（导入成功后调用）。
    static func removeRecoveryFile() {
        try? FileManager.default.removeItem(at: liveRecoveryURL)
    }

    /// 崩溃恢复快照（对外只读结构，AppState 用于重建历史条目）。
    struct RecoveredSnapshot {
        let segments: [TranscriptionSegment]
        let fullText: String
        let translatedSegments: [String]
        let translationLanguage: String?
        let savedAt: Date
    }

    /// 自动保存节流：每 2 秒最多一次（实时循环每轮都触发）。
    @MainActor
    private func throttledAutoSave() {
        let now = Date()
        guard now.timeIntervalSince(lastAutoSaveTime) > 2 else { return }
        lastAutoSaveTime = now
        autoSaveLiveTranscription()
    }

    @MainActor
    private func autoSaveLiveTranscription() {
        guard let appState else { return }
        // 「转录记录」关闭：不写崩溃恢复快照（该录制为纯实时字幕用途，
        // 下次启动不应被恢复成转录历史条目）。
        guard appState.enableLiveTranscription else { return }
        // 会话已结束（stopLive 清空了 liveSegments 并删掉快照）：不再重建。
        // 这是迟到结果的第二道闸——第一道是循环内的 Task.isCancelled 检查；
        // 该写入路径也可能由其它 @MainActor 调用方在停止后触发。
        guard appState.isLiveTranscribing else { return }
        // 快照用字幕层的完整缓存（sealed 200 段 + 当前未封口 tail），而不是
        // 显示窗口 liveSegments（只有 100 段）——长录音崩溃恢复时前半段会
        // 整段缺失（字幕层保留 200 段正是为这种情况）。
        let cached = subtitleManager.sealedSegments + subtitleManager.pendingTailSegments
        let segments = cached.isEmpty ? appState.liveSegments : cached
        guard !segments.isEmpty else { return }
        let text = segments.map { $0.text }.joined()
        // 同 finishRecording：实时译文从字幕历史按原文回填
        //（liveTranslatedSegments 无写入点，读它恒为空 → 崩溃恢复丢译文）。
        let translations = SubtitleHistoryManager.shared.alignedTranslations(for: segments)
        let lang: String? = !translations.isEmpty
            ? UserDefaults.standard.string(forKey: "targetLanguage")
            : nil
        let data = LiveRecoveryData(
            segments: segments,
            fullText: text,
            translatedSegments: translations,
            translationLanguage: lang,
            savedAt: Date()
        )
        if let encoded = try? JSONEncoder().encode(data) {
            try? FileManager.default.createDirectory(
                at: Self.liveRecoveryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // 原子写：该文件的唯一用途就是崩溃/断电恢复，非原子写中途崩溃会
            // 留下截断 JSON → loadRecoveredSnapshot 解码失败静默丢数据。
            do {
                try encoded.write(to: Self.liveRecoveryURL, options: .atomic)
            } catch {
                AppLogger.shared.log(.asr, "live recovery snapshot write failed: \(error.localizedDescription)")
            }
        }
    }

    private func removeLiveRecoveryFile() {
        try? FileManager.default.removeItem(at: Self.liveRecoveryURL)
    }

    // MARK: - Timeout helper

    struct TimeoutError: Error {}

    /// Run `operation` with a timeout. If it doesn't complete within `seconds`, throws TimeoutError.
    ///
    /// **不能用 throwing task group**：作用域退出时会等待全部子任务结束，
    /// 而 whisper_full / Qwen / Nemotron 的推理都是 actor 内同步调用、不检查
    /// 取消 → 拿到 TimeoutError 后仍要等推理跑完才返回，超时形同虚设
    ///（GPU 死锁时 live loop 永久冻结，看门狗「连续 2 次超时卸载模型重建」
    /// 的恢复路径不可达）。
    ///
    /// 改为「独立任务 + 单次 resume 竞速」：超时/取消立刻返回，后台推理
    /// 继续跑完（其 actor 隔离挡住下一轮并发推理，但循环能感知并计数上报）。
    /// internal（非 private）：供单测验证"对不可协作取消的工作也真的会超时"。
    static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        // 一次性 resume 闸：三个竞速方（推理完成 / 超时 / 取消）都经此收口。
        let gate = TimeoutRaceGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                Task {
                    do { gate.finish(.success(try await operation())) }
                    catch { gate.finish(.failure(error)) }
                }
                Task {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }   // sleep 被取消：由 onCancel 收尾
                    gate.finish(.failure(TimeoutError()))
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

/// `withTimeout` 的单次 resume 闸：多方竞速（推理完成 / 超时 / 取消），
/// 只允许第一个结果生效。用锁而非 actor：`install` 必须在
/// `withCheckedThrowingContinuation` 的**同步**体内调用（actor 是异步的）。
private final class TimeoutRaceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        // 极端情形：安装前已有结果（调用方在 install 之前就 finish）。
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
