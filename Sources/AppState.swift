import Foundation
import Observation

@Observable
class AppState {
    var items: [TranscriptionItem] = []
    var selectedItemID: UUID?

    private let service = TranscriptionService()

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
        startTranscription(for: item)
    }

    func retranscribe(_ item: TranscriptionItem) {
        item.segments = []
        item.fullText = ""
        item.progress = 0
        startTranscription(for: item)
    }

    func removeItem(_ item: TranscriptionItem) {
        items.removeAll { $0.id == item.id }
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
    }

    private func startTranscription(for item: TranscriptionItem) {
        item.status = .transcribing
        item.progress = 0
        item.transcriptionStartTime = Date()

        Task.detached { [service] in
            do {
                let result = try await service.transcribe(fileURL: item.fileURL) { progress in
                    // WhisperDelegate dispatches to main queue already
                    Task { @MainActor in
                        item.progress = progress
                    }
                }
                await MainActor.run {
                    item.segments = result.segments
                    item.fullText = result.text
                    item.status = .completed
                }
            } catch {
                await MainActor.run {
                    item.status = .failed(error.localizedDescription)
                }
            }
        }
    }
}
