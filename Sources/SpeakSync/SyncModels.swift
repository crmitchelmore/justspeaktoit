import Foundation

/// A platform-agnostic transcription history entry for CloudKit sync.
/// Both iOS and macOS map their native history types to/from this model.
public struct SyncableHistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let rawTranscription: String?
    public let postProcessedText: String?
    public let model: String
    public let duration: TimeInterval
    public let wordCount: Int
    public let originPlatform: String
    public let updatedAt: Date

    public init(
        id: UUID,
        createdAt: Date,
        rawTranscription: String?,
        postProcessedText: String?,
        model: String,
        duration: TimeInterval,
        wordCount: Int,
        originPlatform: String,
        updatedAt: Date
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscription = rawTranscription
        self.postProcessedText = postProcessedText
        self.model = model
        self.duration = duration
        self.wordCount = wordCount
        self.originPlatform = originPlatform
        self.updatedAt = updatedAt
    }
}

/// The upload conflict rule every History transport applies after looking up
/// the existing record: a CloudKit copy at least as new as the local entry is
/// acknowledged and reconciled locally instead of being overwritten.
enum HistoryConflictPolicy {
    static func remoteWins(_ remote: SyncableHistoryEntry, over local: SyncableHistoryEntry) -> Bool {
        remote.updatedAt >= local.updatedAt
    }
}

/// Errors that can occur during sync.
public enum SyncError: LocalizedError {
    case cloudUnavailable
    case cloudKit(Error)
    case delegateUnavailable
    case invalidChangePage
    case partialUploadFailure(Int)
    case reconciliationIncomplete(Int)
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            return "iCloud is not available. Please sign in to iCloud in Settings."
        case .cloudKit(let error):
            return "CloudKit error: \(error.localizedDescription)"
        case .delegateUnavailable:
            return "History sync is not ready yet"
        case .invalidChangePage:
            return "CloudKit returned another history page without a change token"
        case .partialUploadFailure(let count):
            return "Failed to upload \(count) history entr\(count == 1 ? "y" : "ies")"
        case .reconciliationIncomplete(let count):
            return "History reconciliation left \(count) entr\(count == 1 ? "y" : "ies") pending"
        case .encodingFailed:
            return "Failed to encode data for sync"
        case .decodingFailed:
            return "Failed to decode synced data"
        }
    }
}
