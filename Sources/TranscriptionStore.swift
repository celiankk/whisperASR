import Foundation

enum TranscriptionStore {

    // MARK: - Codable DTO

    private struct StoredItem: Codable {
        let id: UUID
        let fileName: String
        let filePath: String
        let segments: [TranscriptionSegment]
        let fullText: String
        let dateAdded: Date
        let statusTag: String          // "completed", "failed", "pending"
        let errorMessage: String?
    }

    // MARK: - Directory

    private static var storeDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("Transcriptions", isDirectory: true)
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: storeDirectory, withIntermediateDirectories: true
        )
    }

    private static func fileURL(for id: UUID) -> URL {
        storeDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Save

    static func save(_ item: TranscriptionItem) {
        ensureDirectory()

        let statusTag: String
        let errorMessage: String?
        switch item.status {
        case .completed:
            statusTag = "completed"
            errorMessage = nil
        case .failed(let msg):
            statusTag = "failed"
            errorMessage = msg
        default:
            statusTag = "pending"
            errorMessage = nil
        }

        let stored = StoredItem(
            id: item.id,
            fileName: item.fileName,
            filePath: item.fileURL.path,
            segments: item.segments,
            fullText: item.fullText,
            dateAdded: item.dateAdded,
            statusTag: statusTag,
            errorMessage: errorMessage
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: fileURL(for: item.id), options: .atomic)
    }

    // MARK: - Load

    static func loadAll() -> [TranscriptionItem] {
        ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storeDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> TranscriptionItem? in
                guard let data = try? Data(contentsOf: url),
                      let stored = try? decoder.decode(StoredItem.self, from: data)
                else { return nil }

                let status: TranscriptionStatus
                switch stored.statusTag {
                case "completed": status = .completed
                case "failed":    status = .failed(stored.errorMessage ?? "Unknown error")
                default:          status = .pending
                }

                return TranscriptionItem(
                    id: stored.id,
                    fileName: stored.fileName,
                    fileURL: URL(fileURLWithPath: stored.filePath),
                    dateAdded: stored.dateAdded,
                    status: status,
                    segments: stored.segments,
                    fullText: stored.fullText
                )
            }
            .sorted { $0.dateAdded < $1.dateAdded }
    }

    // MARK: - Delete

    static func delete(_ item: TranscriptionItem) {
        try? FileManager.default.removeItem(at: fileURL(for: item.id))
        try? FileManager.default.removeItem(at: item.fileURL)
    }
}
