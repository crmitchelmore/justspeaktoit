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
/// fields below and never has to be redeployed for a new per-entry metric.
public enum ComparisonSyncRecord {
    public static let recordType = "ModelComparisonRound"

    enum FieldKey {
        static let roundID = "roundID"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
        static let originPlatform = "originPlatform"
        static let schemaVersion = "schemaVersion"
        static let payload = "payload"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func recordID(for roundID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "comparison-\(roundID.uuidString)", zoneID: SyncConfiguration.zoneID)
    }

    /// The round id a record name encodes, or `nil` for other record names.
    public static func roundID(fromRecordName name: String) -> UUID? {
        guard name.hasPrefix("comparison-") else { return nil }
        return UUID(uuidString: String(name.dropFirst("comparison-".count)))
    }

    public static func record(from round: ModelComparisonRound, existingRecord: CKRecord? = nil) throws -> CKRecord {
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID(for: round.id))
        record[FieldKey.roundID] = round.id.uuidString
        record[FieldKey.createdAt] = round.createdAt
        record[FieldKey.updatedAt] = round.updatedAt
        record[FieldKey.originPlatform] = round.originPlatform
        record[FieldKey.schemaVersion] = ModelComparisonRound.schemaVersion
        guard let payload = String(data: try encoder.encode(round), encoding: .utf8) else {
            throw SyncError.encodingFailed
        }
        record[FieldKey.payload] = payload
        return record
    }

    /// Decodes a round, or `nil` when the record is not a decodable round —
    /// including a payload written by a newer schema this build cannot read,
    /// which is skipped rather than surfaced as a broken round.
    public static func round(from record: CKRecord) -> ModelComparisonRound? {
        guard record.recordType == recordType,
              let payload = record[FieldKey.payload] as? String,
              let version = record[FieldKey.schemaVersion] as? Int,
              version <= ModelComparisonRound.schemaVersion else {
            return nil
        }
        guard var round = try? decoder.decode(ModelComparisonRound.self, from: Data(payload.utf8)) else {
            return nil
        }
        // The flat field is the sync ordering authority; the payload copy is
        // kept consistent so a re-upload carries the same value.
        if let updatedAt = record[FieldKey.updatedAt] as? Date, updatedAt > round.updatedAt {
            round.updatedAt = updatedAt
        }
        return round
    }
}
