#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync

// MARK: - History Item Model

/// A single transcription history entry for iOS.
public struct iOSHistoryItem: Identifiable, Codable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let transcription: String
    /// Polished (post-processed) text, when the entry has been reprocessed.
    public let postProcessedTranscription: String?
    public let model: String
    public let duration: TimeInterval
    public let wordCount: Int
    public let originPlatform: String
    public let originDeviceID: String
    /// Most recent error captured for this entry (e.g. a failed reprocess),
    /// surfaced in the history UI. Local-only — not synced.
    public let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, transcription, postProcessedTranscription, model, duration, wordCount
        case originPlatform, originDeviceID, errorMessage
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        transcription: String,
        postProcessedTranscription: String? = nil,
        model: String,
        duration: TimeInterval,
        wordCount: Int,
        originPlatform: String = "ios",
        originDeviceID: String = DeviceIdentity.deviceId,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.transcription = transcription
        self.postProcessedTranscription = postProcessedTranscription
        self.model = model
        self.duration = duration
        self.wordCount = wordCount
        self.originPlatform = originPlatform
        self.originDeviceID = originDeviceID
        self.errorMessage = errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = createdAt
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.transcription = try container.decode(String.self, forKey: .transcription)
        self.postProcessedTranscription =
            try container.decodeIfPresent(String.self, forKey: .postProcessedTranscription)
        self.model = try container.decode(String.self, forKey: .model)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.wordCount = try container.decode(Int.self, forKey: .wordCount)
        self.originPlatform = try container.decodeIfPresent(String.self, forKey: .originPlatform) ?? "ios"
        self.originDeviceID = try container.decodeIfPresent(String.self, forKey: .originDeviceID)
            ?? DeviceIdentity.deviceId
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    /// The best available transcript for copy/display: polished if present, else raw.
    public var bestText: String {
        postProcessedTranscription ?? transcription
    }

    /// Whether a polished version exists.
    public var hasPolishedText: Bool {
        !(postProcessedTranscription ?? "").isEmpty
    }

    /// Returns a copy with the polished transcript set and any prior error cleared.
    public func withPostProcessed(_ text: String, updatedAt: Date = Date()) -> iOSHistoryItem {
        iOSHistoryItem(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            transcription: transcription,
            postProcessedTranscription: text,
            model: model,
            duration: duration,
            wordCount: wordCount,
            originPlatform: originPlatform,
            originDeviceID: originDeviceID,
            errorMessage: nil
        )
    }

    /// Returns a copy carrying an error message (e.g. a failed reprocess).
    public func withError(_ message: String?) -> iOSHistoryItem {
        iOSHistoryItem(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            transcription: transcription,
            postProcessedTranscription: postProcessedTranscription,
            model: model,
            duration: duration,
            wordCount: wordCount,
            originPlatform: originPlatform,
            originDeviceID: originDeviceID,
            errorMessage: message
        )
    }

    /// Convert to a syncable entry for CloudKit.
    func toSyncable() -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: createdAt,
            rawTranscription: transcription,
            postProcessedText: postProcessedTranscription,
            model: model,
            duration: duration,
            wordCount: wordCount,
            originPlatform: originPlatform,
            updatedAt: updatedAt,
            originDeviceID: originDeviceID
        )
    }

    /// Create from a synced remote entry.
    static func fromSyncable(_ entry: SyncableHistoryEntry) -> iOSHistoryItem {
        iOSHistoryItem(
            id: entry.id,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            transcription: entry.rawTranscription ?? entry.postProcessedText ?? "",
            postProcessedTranscription: entry.postProcessedText,
            model: entry.model,
            duration: entry.duration,
            wordCount: entry.wordCount,
            originPlatform: entry.originPlatform,
            originDeviceID: entry.originDeviceID
        )
    }
}
#endif
