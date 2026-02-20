import CloudKit
import Foundation

/// Handles conversion between transcription history and CKRecord.
public struct SyncRecord {

    // MARK: - CKRecord Field Keys

    private enum FieldKey {
        static let entryID = "entryID"
        static let createdAt = "createdAt"
        static let rawTranscription = "rawTranscription"
        static let postProcessedText = "postProcessedText"
        static let model = "model"
        static let duration = "duration"
        static let wordCount = "wordCount"
        static let originPlatform = "originPlatform"
        static let updatedAt = "updatedAt"
    }

    // MARK: - Syncable Entry

    /// Creates a CKRecord from a SyncableHistoryEntry.
    public static func record(
        from entry: SyncableHistoryEntry,
        existingRecord: CKRecord? = nil
    ) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: entry.id.uuidString,
            zoneID: SyncConfiguration.zoneID
        )

        let record = existingRecord ?? CKRecord(
            recordType: SyncConfiguration.recordType,
            recordID: recordID
        )

        record[FieldKey.entryID] = entry.id.uuidString
        record[FieldKey.createdAt] = entry.createdAt
        record[FieldKey.rawTranscription] = entry.rawTranscription
        record[FieldKey.postProcessedText] = entry.postProcessedText
        record[FieldKey.model] = entry.model
        record[FieldKey.duration] = entry.duration
        record[FieldKey.wordCount] = entry.wordCount
        record[FieldKey.originPlatform] = entry.originPlatform
        record[FieldKey.updatedAt] = entry.updatedAt

        return record
    }

    /// Creates a SyncableHistoryEntry from a CKRecord.
    public static func entry(from record: CKRecord) -> SyncableHistoryEntry? {
        guard
            let idString = record[FieldKey.entryID] as? String,
            let entryID = UUID(uuidString: idString),
            let createdAt = record[FieldKey.createdAt] as? Date
        else {
            return nil
        }

        let rawTranscription = record[FieldKey.rawTranscription] as? String
        let postProcessedText = record[FieldKey.postProcessedText] as? String
        let model = record[FieldKey.model] as? String ?? "unknown"
        let duration = record[FieldKey.duration] as? Double ?? 0
        let wordCount = record[FieldKey.wordCount] as? Int ?? 0
        let originPlatform = record[FieldKey.originPlatform] as? String ?? "unknown"
        let updatedAt = record[FieldKey.updatedAt] as? Date ?? createdAt

        return SyncableHistoryEntry(
            id: entryID,
            createdAt: createdAt,
            rawTranscription: rawTranscription,
            postProcessedText: postProcessedText,
            model: model,
            duration: duration,
            wordCount: wordCount,
            originPlatform: originPlatform,
            updatedAt: updatedAt
        )
    }
}
