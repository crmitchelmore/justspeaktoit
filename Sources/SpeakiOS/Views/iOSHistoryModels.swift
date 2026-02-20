#if os(iOS)
import Foundation
import SpeakSync

// MARK: - History Item Model

/// A single transcription history entry for iOS.
public struct iOSHistoryItem: Identifiable, Codable {
    public let id: UUID
    public let createdAt: Date
    public let transcription: String
    public let model: String
    public let duration: TimeInterval
    public let wordCount: Int
    public let originPlatform: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcription: String,
        model: String,
        duration: TimeInterval,
        wordCount: Int,
        originPlatform: String = "ios"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcription = transcription
        self.model = model
        self.duration = duration
        self.wordCount = wordCount
        self.originPlatform = originPlatform
    }

    /// Convert to a syncable entry for CloudKit.
    func toSyncable() -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: createdAt,
            rawTranscription: transcription,
            postProcessedText: nil,
            model: model,
            duration: duration,
            wordCount: wordCount,
            originPlatform: originPlatform,
            updatedAt: createdAt
        )
    }

    /// Create from a synced remote entry.
    static func fromSyncable(_ entry: SyncableHistoryEntry) -> iOSHistoryItem {
        let text = entry.postProcessedText
            ?? entry.rawTranscription
            ?? ""
        return iOSHistoryItem(
            id: entry.id,
            createdAt: entry.createdAt,
            transcription: text,
            model: entry.model,
            duration: entry.duration,
            wordCount: entry.wordCount,
            originPlatform: entry.originPlatform
        )
    }
}
#endif
