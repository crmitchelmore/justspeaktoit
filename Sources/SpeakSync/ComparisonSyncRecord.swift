import CloudKit
import Foundation
import SpeakCore

/// CKRecord mapping for Compare Models rounds (issue #1101).
///
/// Rounds live in the existing `TranscriptionHistoryZone` as their own record
/// type so they ride the same container, zone and iCloud account as History
/// without touching the History record schema. The round itself is stored as
/// one JSON payload: the shape is versioned by `ModelComparisonRound.schemaVersion`
/// and evolves through Codable, so the CloudKit schema only needs the few flat
/// fields in `SyncSchema.ComparisonRound` and never has to be redeployed for a
/// new per-entry metric. Encoding and validation are the shared
/// `ComparisonRecordCodec`, which CloudKit Web Services uses too.
public enum ComparisonSyncRecord {
    public static let recordType = SyncSchema.ComparisonRound.recordType

    public static func recordID(for roundID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: SyncSchema.ComparisonRound.recordName(for: roundID), zoneID: SyncConfiguration.zoneID)
    }

    /// The round id a record name encodes, or `nil` for other record names.
    public static func roundID(fromRecordName name: String) -> UUID? {
        SyncSchema.ComparisonRound.roundID(fromRecordName: name)
    }

    public static func record(from round: ModelComparisonRound, existingRecord: CKRecord? = nil) throws -> CKRecord {
        let assignments = try ComparisonRecordCodec.assignments(for: round)
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID(for: round.id))
        var fields = CloudKitRecordFields(record)
        fields.apply(assignments)
        return record
    }

    /// Decodes a round, or `nil` when the record is not a decodable round —
    /// including a payload written by a newer schema this build cannot read,
    /// which is skipped rather than surfaced as a broken round.
    public static func round(from record: CKRecord) -> ModelComparisonRound? {
        ComparisonRecordCodec.round(from: CloudKitRecordFields(record))
    }

    /// Tombstones use the same payload and flat fields, with no additional schema fields.
    static func record(from revision: ModelComparisonRevision, existingRecord: CKRecord? = nil) throws -> CKRecord {
        let assignments = try ComparisonRecordCodec.assignments(for: revision)
        let roundID = revision.round?.id ?? revision.id
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID(for: roundID))
        var fields = CloudKitRecordFields(record)
        fields.apply(assignments)
        return record
    }

    static func revision(from record: CKRecord) throws -> ModelComparisonRevision {
        try ComparisonRecordCodec.revision(from: CloudKitRecordFields(record))
    }
}
