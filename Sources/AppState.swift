import Foundation
import Observation

@Observable
class AppState {
    var items: [TranscriptionItem] = []
    var selectedItemID: UUID?

    // Live transcription state
    var liveSegments: [TranscriptionSegment] = []
    var liveText: String = ""
    var isLiveTranscribing = false
    var enableLiveTranscription = true

    // Live translation state (per-segment)
    var liveTranslatedSegments: [String] = []
    var enableLiveTranslation = false
    private var liveTranslatedSourceTexts: [String] = []  // tracks what text each translation was for

    private let service = TranscriptionService()
    private var isTranscribing = false
    private var liveTranscriptionTask: Task<Void, Never>?
    private var isChunkTranscribing = false
    private var lastAutoSaveTime: Date = .distantPast

    /// Maximum chunk duration sent to whisper (30 seconds at 16kHz).
    /// Caps processing time so the loop never snowballs.
    private static let maxChunkSamples = 16000 * 30

    init() {
        items = TranscriptionStore.loadAll()
        selectedItemID = items.first?.id
        // Auto-resume any pending items restored from disk
        if items.contains(where: { $0.status == .pending }) {
            startNextTranscription()
        }
    }

    var selectedItem: TranscriptionItem? {
        items.first { $0.id == selectedItemID }
    }

    func addFile(url: URL) {
        guard !items.contains(where: { $0.fileURL == url }) else {
            selectedItemID = items.first { $0.fileURL == url }?.id
            return
        }

        let item = TranscriptionItem(fileURL: url)
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        enqueueTranscription(for: item)
    }

    func retranscribe(_ item: TranscriptionItem) {
        item.segments = []
        item.fullText = ""
        item.progress = 0
        item.translatedSegments = []
        item.translationLanguage = nil
        enqueueTranscription(for: item)
    }

    func renameItem(_ item: TranscriptionItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Preserve the file extension
        let ext = item.fileURL.pathExtension
        let nameWithExt = trimmed.hasSuffix(".\(ext)") ? trimmed : "\(trimmed).\(ext)"

        // Rename the actual file on disk
        let newURL = item.fileURL.deletingLastPathComponent().appendingPathComponent(nameWithExt)
        if newURL != item.fileURL {
            try? FileManager.default.moveItem(at: item.fileURL, to: newURL)
            item.fileURL = newURL
        }
        item.fileName = nameWithExt
        TranscriptionStore.save(item)
    }

    /// Add a file with pre-existing live transcription results (skip re-transcription).
    func addFileWithLiveResults(url: URL, segments: [TranscriptionSegment], fullText: String,
                                translatedSegments: [String] = [], translationLanguage: String? = nil) {
        let item = TranscriptionItem(fileURL: url)
        item.segments = segments
        item.fullText = fullText
        item.translatedSegments = translatedSegments
        item.translationLanguage = translationLanguage
        item.status = .completed
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
    }

    // MARK: - Translate Completed Transcription

    func translateItem(_ item: TranscriptionItem, targetLanguage: String) {
        guard !item.segments.isEmpty, !item.isTranslating else { return }
        item.isTranslating = true
        item.translatedSegments = Array(repeating: "", count: item.segments.count)
        item.translationLanguage = targetLanguage

        Task {
            let texts = item.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let batchSize = 20

            for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, texts.count)
                let batch = Array(texts[batchStart..<batchEnd])

                let contextStart = max(0, batchStart - 2)
                let contextPairs: [(original: String, translated: String)] = (contextStart..<batchStart).compactMap { i in
                    guard !texts[i].isEmpty, !item.translatedSegments[i].isEmpty else { return nil }
                    return (original: texts[i], translated: item.translatedSegments[i])
                }

                do {
                    let translations = try await TranslationService.translateSegmentsWithOpenAI(
                        segmentTexts: batch,
                        targetLanguage: targetLanguage,
                        previousTranslations: contextPairs
                    )
                    for (offset, translation) in translations.enumerated() {
                        item.translatedSegments[batchStart + offset] = translation
                    }
                } catch {
                    print("[Translation] batch error: \(error)")
                }
            }

            item.isTranslating = false
            TranscriptionStore.save(item)
        }
    }

    func clearTranslation(_ item: TranscriptionItem) {
        item.translatedSegments = []
        item.translationLanguage = nil
        TranscriptionStore.save(item)
    }

    func shutdown() {
        service.shutdown()
    }

    func removeItem(_ item: TranscriptionItem) {
        items.removeAll { $0.id == item.id }
        TranscriptionStore.delete(item)
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
    }

    private func enqueueTranscription(for item: TranscriptionItem) {
        item.status = .pending
        if !isTranscribing {
            startNextTranscription()
        }
    }

    private func startNextTranscription() {
        guard let item = items.first(where: { $0.status == .pending }) else {
            isTranscribing = false
            return
        }
        isTranscribing = true
        item.status = .transcribing
        item.progress = 0
        item.transcriptionStartTime = Date()

        Task.detached { [service] in
            do {
                let result = try await service.transcribe(fileURL: item.fileURL) { progress in
                    Task { @MainActor in
                        item.progress = progress
                    }
                }
                await MainActor.run {
                    item.segments = result.segments
                    item.fullText = result.text
                    item.status = .completed
                    TranscriptionStore.save(item)
                }
            } catch {
                await MainActor.run {
                    item.status = .failed(error.localizedDescription)
                    TranscriptionStore.save(item)
                }
            }
            await MainActor.run { [weak self] in
                self?.startNextTranscription()
            }
        }
    }

    // MARK: - Live Transcription During Recording

    /// Start periodic live transcription from the AudioRecorder's accumulated PCM buffer.
    func startLiveTranscription(recorder: AudioRecorder) {
        liveSegments = []
        liveText = ""
        isLiveTranscribing = true
        isChunkTranscribing = false

        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }

            // Pre-load the model and wait for it — avoids model loading latency on first chunk
            try? self.service.preloadModel()
            guard !Task.isCancelled else { return }

            var committedSegments: [TranscriptionSegment] = []
            var committedSampleCount = 0

            while !Task.isCancelled {
                // Don't overlap chunk transcriptions; skip if one is still running
                if !self.isChunkTranscribing {
                    // Only read the sample count (no copy) to check for new audio
                    let totalSamples = recorder.accumulatedSampleCount
                    let newSampleCount = totalSamples - committedSampleCount

                    // Only transcribe if we have at least 0.5 seconds of NEW audio (8000 samples)
                    if newSampleCount >= 8000 {
                        self.isChunkTranscribing = true

                        // Include 1 second of overlap from previous chunk for context
                        let contextSamples = min(committedSampleCount, 16000 * 1)

                        // Cap chunk size to prevent snowball: if we've fallen behind,
                        // skip ahead so we only transcribe the most recent audio.
                        let maxNew = Self.maxChunkSamples - contextSamples
                        let effectiveCommitted: Int
                        if newSampleCount > maxNew {
                            // Skip ahead — we can't keep up, prioritize recent audio
                            effectiveCommitted = totalSamples - maxNew
                        } else {
                            effectiveCommitted = committedSampleCount
                        }
                        let chunkStart = effectiveCommitted - min(effectiveCommitted, 16000 * 1)
                        // Only copy the chunk we need, not the entire buffer
                        let chunk = recorder.getSamples(from: chunkStart)
                        let timeOffset = Double(chunkStart) / 16000.0

                        do {
                            let result = try await self.service.transcribeChunk(samples: chunk)

                            // Offset timestamps to match position in the full stream
                            let newSegments = result.segments.map { seg in
                                TranscriptionSegment(
                                    start: seg.start + timeOffset,
                                    end: seg.end.map { $0 + timeOffset },
                                    text: seg.text
                                )
                            }

                            // Keep committed segments before the context overlap window
                            let contextTime = Double(chunkStart) / 16000.0
                            let kept = committedSegments.filter { $0.start < contextTime }

                            // Add new segments, trimming any text at the start that
                            // duplicates the end of the last segment (caused by the
                            // 2s overlap re-transcription).
                            var allSegments = kept
                            for seg in newSegments {
                                var text = seg.text
                                if let lastText = allSegments.last?.text {
                                    let suffixSource = lastText.trimmingCharacters(in: .whitespaces)
                                    let prefixTarget = text.trimmingCharacters(in: .whitespaces)
                                    // Find longest suffix of last segment that matches
                                    // prefix of this segment, then trim it
                                    let maxCheck = min(suffixSource.count, prefixTarget.count)
                                    for len in stride(from: maxCheck, through: 4, by: -1) {
                                        let suffix = String(suffixSource.suffix(len))
                                        if prefixTarget.hasPrefix(suffix) {
                                            text = String(prefixTarget.dropFirst(len))
                                            break
                                        }
                                    }
                                }
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    allSegments.append(TranscriptionSegment(
                                        start: seg.start, end: seg.end, text: text))
                                }
                            }

                            committedSegments = allSegments
                            committedSampleCount = totalSamples

                            // Trim old PCM samples we'll never need again
                            // (keep 1s of overlap for next chunk's context)
                            let safeToTrim = max(0, committedSampleCount - 16000 * 1)
                            recorder.trimSamples(upTo: safeToTrim)

                            await MainActor.run {
                                self.liveSegments = allSegments
                                self.isChunkTranscribing = false
                                self.throttledAutoSave()
                            }
                            // Translate if live translation is enabled
                            if self.enableLiveTranslation && !allSegments.isEmpty {
                                let targetLang = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
                                if !targetLang.isEmpty {
                                    await self.translateLiveSegments(allSegments, targetLang: targetLang)
                                }
                            }
                        } catch {
                            print("[AppState] live transcription chunk error: \(error)")
                            await MainActor.run {
                                self.isChunkTranscribing = false
                            }
                        }
                    }
                }

                // Wait before the next chunk
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Stop the live transcription timer. Called when recording ends.
    func stopLiveTranscription() {
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        isLiveTranscribing = false
        isChunkTranscribing = false
        // Clear live results (the final file transcription will replace them)
        liveSegments = []
        liveText = ""
        liveTranslatedSegments = []
        liveTranslatedSourceTexts = []
        enableLiveTranslation = false
        removeLiveRecoveryFile()
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

    /// Only auto-save at most every 15 seconds to avoid JSON serialization overhead.
    @MainActor
    private func throttledAutoSave() {
        let now = Date()
        guard now.timeIntervalSince(lastAutoSaveTime) >= 15 else { return }
        lastAutoSaveTime = now
        autoSaveLiveTranscription()
    }

    /// Persist current live transcription to a recovery file so data survives a hang or crash.
    @MainActor
    private func autoSaveLiveTranscription() {
        let segments = liveSegments
        let text = segments.map { $0.text }.joined()
        let translations = liveTranslatedSegments
        let lang: String? = !translations.isEmpty
            ? UserDefaults.standard.string(forKey: "targetLanguage") : nil

        // Write on a background queue to avoid blocking the main thread
        Task.detached(priority: .utility) {
            let data = LiveRecoveryData(
                segments: segments, fullText: text,
                translatedSegments: translations, translationLanguage: lang,
                savedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let json = try? encoder.encode(data) else { return }
            let url = AppState.liveRecoveryURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: url, options: .atomic)
        }
    }

    private func removeLiveRecoveryFile() {
        try? FileManager.default.removeItem(at: Self.liveRecoveryURL)
    }

    /// Check if there is a recoverable live transcription from a previous crash/hang.
    var hasLiveRecoveryData: Bool {
        FileManager.default.fileExists(atPath: Self.liveRecoveryURL.path)
    }

    /// Import recovered live transcription as a completed transcription item.
    func importRecoveredTranscription() {
        let url = Self.liveRecoveryURL
        guard let data = try? Data(contentsOf: url),
              let recovery = try? JSONDecoder().decode(LiveRecoveryData.self, from: data)
        else { return }
        let item = TranscriptionItem(
            fileURL: URL(fileURLWithPath: "/recovered-\(ISO8601DateFormatter().string(from: recovery.savedAt))"))
        item.segments = recovery.segments
        item.fullText = recovery.fullText
        item.translatedSegments = recovery.translatedSegments
        item.translationLanguage = recovery.translationLanguage
        item.status = .completed
        item.fileName = "Recovered \(DateFormatter.localizedString(from: recovery.savedAt, dateStyle: .short, timeStyle: .short))"
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        removeLiveRecoveryFile()
    }

    // MARK: - Live Translation

    private func translateLiveSegments(_ segments: [TranscriptionSegment], targetLang: String) async {
        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let (existing, existingSourceTexts) = await MainActor.run {
            (self.liveTranslatedSegments, self.liveTranslatedSourceTexts)
        }

        // Find the first index where the segment text changed or has no translation.
        // Segments in the overlap zone may be re-transcribed with different text,
        // so we need to re-translate from the first divergent segment onward.
        var firstDirtyIndex = min(existing.count, texts.count)
        for i in 0..<min(existing.count, existingSourceTexts.count, texts.count) {
            if texts[i] != existingSourceTexts[i] || existing[i].isEmpty {
                firstDirtyIndex = i
                break
            }
        }

        let dirtyIndex = firstDirtyIndex  // capture for Sendable closure
        let textsToTranslate = Array(texts.dropFirst(dirtyIndex))
        guard !textsToTranslate.isEmpty else { return }

        // Use up to 2 clean translations before the dirty range as context
        let contextStart = max(0, dirtyIndex - 2)
        let contextPairs: [(original: String, translated: String)] = (contextStart..<dirtyIndex).compactMap { i in
            guard i < texts.count, i < existing.count,
                  !texts[i].isEmpty, !existing[i].isEmpty else { return nil }
            return (original: texts[i], translated: existing[i])
        }

        do {
            let newTranslations = try await TranslationService.translateSegmentsWithOpenAI(
                segmentTexts: textsToTranslate, targetLanguage: targetLang,
                previousTranslations: contextPairs)
            await MainActor.run {
                self.liveTranslatedSegments = Array(existing.prefix(dirtyIndex)) + newTranslations
                self.liveTranslatedSourceTexts = Array(texts.prefix(dirtyIndex)) + textsToTranslate
            }
        } catch {
            print("[Translation] OpenAI error: \(error)")
            // On error, pad so next cycle can retry the failed segments
            await MainActor.run {
                if self.liveTranslatedSegments.count < texts.count {
                    self.liveTranslatedSegments += Array(repeating: "", count: texts.count - self.liveTranslatedSegments.count)
                    self.liveTranslatedSourceTexts += texts.suffix(texts.count - self.liveTranslatedSourceTexts.count)
                }
            }
        }
    }
}
