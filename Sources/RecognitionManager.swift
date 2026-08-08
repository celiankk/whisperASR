import Foundation

// MARK: - 识别管理器（RecognitionManager）
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

final class RecognitionManager: @unchecked Sendable {
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

    private var liveTranscriptionTask: Task<Void, Never>?
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
        appState?.liveSegments = []
        appState?.liveError = nil
        appState?.liveTranslationError = nil
        appState?.liveTranslationPaused = false
        appState?.isLiveTranscribing = true
        translationManager.resetForStop()
        subtitleManager.start()
        SubtitleHistoryManager.shared.clear()
        liveRecorder = recorder
        startHealthCheck()
        AppLogger.shared.log(.asr, "Live transcription started")

        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }

            // Pre-load the model and wait for it — avoids model loading latency on first chunk.
            // Surface load failures so the user isn't stuck at a silent "Waiting for audio...".
            do {
                try await self.service.preloadLiveModel()
            } catch {
                ErrorManager.shared.report(
                    .model, error,
                    context: "preloadLiveModel",
                    userFacing: "Couldn't load transcription model: \(error.localizedDescription)"
                )
                await MainActor.run {
                    self.appState?.liveError = "Couldn't load transcription model: \(error.localizedDescription)"
                    self.appState?.isLiveTranscribing = false
                }
                return
            }
            guard !Task.isCancelled else { return }

            // Partial/final streaming model:
            //  - Every pass re-transcribes the unsealed *tail* and shows it immediately, so the
            //    in-progress sentence appears within ~1s (no waiting for a pause).
            //  - Segments before the last silence pause are *sealed* (final) — they stop changing
            //    and are never re-transcribed, which keeps boundaries clean and translation steady.
            var consecutiveSilenceCount = 0
            var lastTranscribedTotal = 0
            // Silence-scan tuning (16kHz): 100ms frames; a run of >=3 (~300ms) counts as a pause.
            let frameSamples = 1600
            let minSilenceFrames = 3
            // 固定下限阈值：干净麦克风输入（底噪 RMS < 0.001）行为与之前一致。
            let baseSilenceThreshold: Float = 0.001
            let contextSamples = 16000   // 1s left-context, used only after a forced seal

            // The loop awaits each transcribeChunk before iterating, so passes never overlap.
            while !Task.isCancelled {
                let totalSamples = recorder.accumulatedSampleCount
                let tailCount = totalSamples - self.subtitleManager.sealedSampleCount

                // Need >=0.5s of unsealed audio and >=0.3s of new audio since the last pass —
                // keeps the live tail fresh without re-transcribing identical audio in a tight loop.
                guard tailCount >= 8000, totalSamples - lastTranscribedTotal >= 4800 else {
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
                let rms = recorder.rmsEnergy(from: self.subtitleManager.sealedSampleCount, count: tailCount)
                guard rms > skipThreshold else {
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
                // dedup so the cut word isn't dropped.
                let useOverlap = !self.subtitleManager.sealedClean
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
                guard !chunk.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                lastTranscribedTotal = totalSamples
                let timeOffset = Double(tailStart) / 16000.0

                // Cap the wait so a GPU/Metal hang doesn't deadlock the live loop.
                // Generous: 4× chunk duration, minimum 60s.
                let chunkSeconds = Double(chunk.count) / 16000.0
                let timeoutSeconds = max(60.0, chunkSeconds * 4.0)
                do {
                    let result = try await Self.withTimeout(seconds: timeoutSeconds) {
                        try await self.service.transcribeChunk(samples: chunk)
                    }

                    // Offset timestamps to match position in the full stream.
                    let tailSegments = result.segments.map { seg in
                        TranscriptionSegment(
                            start: seg.start + timeOffset,
                            end: seg.end.map { $0 + timeOffset },
                            text: seg.text
                        )
                    }

                    // Combine sealed (final) + freshly transcribed tail (interim) for display.
                    let tailStartTime = Double(tailStart) / 16000.0
                    let combined = self.subtitleManager.appendTail(
                        tailSegments: tailSegments,
                        tailStartTime: tailStartTime,
                        useOverlap: useOverlap
                    )

                    // Advance the seal: to a trailing pause (clean), or forced once the tail has
                    // grown past the cap without one. Everything before it becomes final.
                    let silenceCut = recorder.lastSilenceCut(
                        searchFrom: self.subtitleManager.sealedSampleCount, searchTo: totalSamples,
                        frameSamples: frameSamples, silenceThreshold: sealSilenceThreshold,
                        minSilenceFrames: minSilenceFrames)
                    var newSeal = self.subtitleManager.sealedSampleCount
                    var newSealClean = self.subtitleManager.sealedClean
                    if let cut = silenceCut, cut - self.subtitleManager.sealedSampleCount >= 8000 {
                        newSeal = cut; newSealClean = true
                    } else if tailCount >= Self.forceChunkSamples {
                        newSeal = totalSamples; newSealClean = false
                    }

                    if newSeal > self.subtitleManager.sealedSampleCount {
                        self.subtitleManager.seal(
                            upToSampleCount: newSeal, clean: newSealClean, combined: combined)
                        // Nothing behind a clean (silence) seal is needed again; keep 1s behind a
                        // forced seal for the next pass's overlap.
                        recorder.trimSamples(upTo: max(0, newSeal - (newSealClean ? 0 : contextSamples)))
                    }

                    let snapshot = self.subtitleManager.snapshot(combined)
                    await MainActor.run {
                        self.appState?.liveSegments = snapshot
                        self.throttledAutoSave()
                    }
                    // 翻译不再按每个快照触发：由字幕层检测到“一句结束”后，
                    // 通过 translateSentence 整句单飞发送（见 Live Translation）。
                } catch is TimeoutError {
                    ErrorManager.shared.report(
                        .asr, context: "chunk timed out after \(timeoutSeconds)s"
                    )
                    await MainActor.run {
                        self.appState?.liveError = "Transcription is slow — the model or GPU may be stuck. Continuing with next chunk."
                    }
                } catch {
                    ErrorManager.shared.report(.asr, error, context: "live transcription chunk")
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
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
            startLive(recorder: recorder)
        }
        appState.showToast("检测到资源异常，已自动清理并继续运行")
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
        let segments = appState.liveSegments
        let text = segments.map { $0.text }.joined()
        let translations = appState.liveTranslatedSegments
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
            try? encoded.write(to: Self.liveRecoveryURL)
        }
    }

    private func removeLiveRecoveryFile() {
        try? FileManager.default.removeItem(at: Self.liveRecoveryURL)
    }

    // MARK: - Timeout helper

    private struct TimeoutError: Error {}

    /// Run `operation` with a timeout. If it doesn't complete within `seconds`, throws TimeoutError.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
