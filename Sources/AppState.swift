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

    // Live translation state (per-segment)
    var liveTranslatedSegments: [String] = []
    var enableLiveTranslation = false

    private let service = TranscriptionService()
    private var isTranscribing = false
    private var liveTranscriptionTask: Task<Void, Never>?
    private var isChunkTranscribing = false

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
        items.append(item)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        enqueueTranscription(for: item)
    }

    func retranscribe(_ item: TranscriptionItem) {
        item.segments = []
        item.fullText = ""
        item.progress = 0
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
                    let allSamples = recorder.getAccumulatedSamples()
                    let newSampleCount = allSamples.count - committedSampleCount

                    // Only transcribe if we have at least 1 second of NEW audio (16000 samples)
                    if newSampleCount >= 16000 {
                        self.isChunkTranscribing = true

                        // Include 2 seconds of overlap from previous chunk for context
                        let contextSamples = min(committedSampleCount, 16000 * 2)
                        let chunkStart = committedSampleCount - contextSamples
                        let chunk = Array(allSamples[chunkStart...])
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
                            let allSegments = kept + newSegments

                            committedSegments = allSegments
                            committedSampleCount = allSamples.count

                            await MainActor.run {
                                self.liveSegments = allSegments
                                self.liveText = allSegments.map { $0.text }.joined()
                                self.isChunkTranscribing = false
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
                try? await Task.sleep(for: .seconds(2))
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
        enableLiveTranslation = false
    }

    // MARK: - Live Translation

    private func translateLiveSegments(_ segments: [TranscriptionSegment], targetLang: String) async {
        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let existing = await MainActor.run { self.liveTranslatedSegments }
        let existingCount = existing.count

        // Only translate segments that don't have translations yet
        let newTexts = Array(texts.dropFirst(existingCount))
        guard !newTexts.isEmpty else { return }

        // Use last 2 existing translations as context for consistency
        let contextStart = max(0, existingCount - 2)
        let contextPairs: [(original: String, translated: String)] = (contextStart..<existingCount).compactMap { i in
            guard i < texts.count, i < existing.count,
                  !texts[i].isEmpty, !existing[i].isEmpty else { return nil }
            return (original: texts[i], translated: existing[i])
        }

        do {
            let newTranslations = try await TranslationService.translateSegmentsWithOpenAI(
                segmentTexts: newTexts, targetLanguage: targetLang,
                previousTranslations: contextPairs)
            await MainActor.run { self.liveTranslatedSegments = existing + newTranslations }
        } catch {
            print("[Translation] OpenAI error: \(error)")
            // On error, pad so next cycle can try the failed segments again
            await MainActor.run {
                if self.liveTranslatedSegments.count < texts.count {
                    self.liveTranslatedSegments += Array(repeating: "", count: texts.count - self.liveTranslatedSegments.count)
                }
            }
        }
    }
}
