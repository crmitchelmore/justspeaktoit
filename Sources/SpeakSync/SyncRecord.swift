import CloudKit
import Foundation

/// Handles conversion between transcription history and CKRecord.
///
/// The field set and value types are the shared `SyncSchema.History` format,
/// which the CloudKit Web Services transport writes identically.
public struct SyncRecord {

    // MARK: - Syncable Entry

    /// Creates a CKRecord from a SyncableHistoryEntry.
    public static func record(
        from entry: SyncableHistoryEntry,
        existingRecord: CKRecord? = nil
    ) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: SyncSchema.History.recordName(for: entry.id),
            zoneID: SyncConfiguration.zoneID
        )

        let record = existingRecord ?? CKRecord(
            recordType: SyncConfiguration.recordType,
            recordID: recordID
        )

        var fields = CloudKitRecordFields(record)
        fields.apply(HistoryRecordCodec.assignments(for: entry))
        return record
    }

    /// Creates a SyncableHistoryEntry from a CKRecord.
    public static func entry(from record: CKRecord) -> SyncableHistoryEntry? {
        HistoryRecordCodec.entry(from: CloudKitRecordFields(record))
    }
}
