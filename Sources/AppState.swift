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
        // Pre-load the model so the first chunk doesn't have loading latency
        Task.detached { [service] in
            try? service.preloadModel()
        }

        liveSegments = []
        liveText = ""
        isLiveTranscribing = true
        isChunkTranscribing = false

        liveTranscriptionTask = Task { [weak self] in
            // Wait a few seconds before the first transcription to accumulate enough audio
            try? await Task.sleep(for: .seconds(5))

            while !Task.isCancelled {
                guard let self else { return }

                // Don't overlap chunk transcriptions; skip if one is still running
                if !self.isChunkTranscribing {
                    let samples = recorder.getAccumulatedSamples()
                    // Only transcribe if we have at least 1 second of audio (16000 samples)
                    if samples.count >= 16000 {
                        self.isChunkTranscribing = true
                        do {
                            let result = try await self.service.transcribeChunk(samples: samples)
                            await MainActor.run {
                                self.liveSegments = result.segments
                                self.liveText = result.text
                                self.isChunkTranscribing = false
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
                try? await Task.sleep(for: .seconds(7))
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
    }
}
