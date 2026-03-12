import Foundation
import Observation

// MARK: - Transcription Segment

struct TranscriptionSegment: Codable, Equatable {
    let start: Double
    let end: Double?
    let text: String
}

// MARK: - Transcription Result (from Python script JSON)

struct TranscriptionResult: Codable {
    let text: String
    let segments: [TranscriptionSegment]
}

// MARK: - Status

enum TranscriptionStatus: Equatable {
    case pending
    case transcribing
    case completed
    case failed(String)
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case processFailed(String)
    case parseError(String)
    case scriptNotFound(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let msg): return "Transcription failed: \(msg)"
        case .parseError(let msg): return "Failed to parse output: \(msg)"
        case .scriptNotFound(let path): return "Script not found at: \(path)"
        }
    }
}

// MARK: - Transcription Item

@Observable
class TranscriptionItem: Identifiable {
    let id: UUID
    let fileName: String
    let fileURL: URL
    var status: TranscriptionStatus = .pending
    var segments: [TranscriptionSegment] = []
    var fullText: String = ""
    var progress: Double = 0
    var transcriptionStartTime: Date?
    let dateAdded: Date

    init(fileURL: URL) {
        self.id = UUID()
        self.fileName = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.dateAdded = Date()
    }

    /// Restore from persisted data
    init(id: UUID, fileName: String, fileURL: URL, dateAdded: Date,
         status: TranscriptionStatus, segments: [TranscriptionSegment], fullText: String) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.dateAdded = dateAdded
        self.status = status
        self.segments = segments
        self.fullText = fullText
    }
}
