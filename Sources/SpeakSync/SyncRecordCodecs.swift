import Foundation
import SpeakCore

/// The ordered fields one record write assigns. A `nil` value clears the field.
typealias SyncRecordFieldAssignments = [(key: String, value: SyncFieldValue?)]

extension SyncRecordFieldWriting {
    mutating func apply(_ assignments: SyncRecordFieldAssignments) {
        for assignment in assignments {
            set(assignment.value, forKey: assignment.key)
        }
    }
}

/// History entry ⇄ `TranscriptionHistory` record, shared by every transport.
enum HistoryRecordCodec {
    private typealias Field = HistoryRecordField

    static func entry(from record: some SyncRecordFieldReading) -> SyncableHistoryEntry? {
        guard
            let idString = record.string(forKey: Field.entryID),
            let entryID = UUID(uuidString: idString),
            let createdAt = record.date(forKey: Field.createdAt)
        else {
            return nil
        }

        return SyncableHistoryEntry(
            id: entryID,
            createdAt: createdAt,
            rawTranscription: record.string(forKey: Field.rawTranscription),
            postProcessedText: record.string(forKey: Field.postProcessedText),
            model: record.string(forKey: Field.model) ?? "unknown",
            duration: record.double(forKey: Field.duration) ?? 0,
            wordCount: record.int(forKey: Field.wordCount) ?? 0,
            originPlatform: record.string(forKey: Field.originPlatform) ?? "unknown",
            updatedAt: record.date(forKey: Field.updatedAt) ?? createdAt
        )
    }

    /// Every field a History write assigns, in the order the native mapper has
    /// always assigned them.
    static func assignments(for entry: SyncableHistoryEntry) -> SyncRecordFieldAssignments {
        [
            (Field.entryID, .string(entry.id.uuidString)),
            (Field.createdAt, .timestamp(entry.createdAt)),
            (Field.rawTranscription, entry.rawTranscription.map(SyncFieldValue.string)),
            (Field.postProcessedText, entry.postProcessedText.map(SyncFieldValue.string)),
            (Field.model, .string(entry.model)),
            (Field.duration, .double(entry.duration)),
            (Field.wordCount, .int64(Int64(entry.wordCount))),
            (Field.originPlatform, .string(entry.originPlatform)),
            (Field.updatedAt, .timestamp(entry.updatedAt))
        ]
    }

    /// A changed record's contribution to a History fetch. Other record types
    /// share the zone (encrypted secrets, comparison rounds) and belong to their
    /// own engines; a History record without a readable id and creation date is
    /// skipped, as it always has been.
    static func change(from record: some SyncRecordFieldReading) -> HistoryRemoteChange? {
        guard record.syncRecordType == SyncSchema.History.recordType,
              let entry = entry(from: record) else {
            return nil
        }
        return .changed(entry)
    }

    /// A deleted record's contribution. `recordType` is `nil` only when a change
    /// feed omits it; the disjoint record names in `SyncSchema` then decide.
    static func deletion(recordName: String, recordType: String?) -> HistoryRemoteChange? {
        if let recordType, recordType != SyncSchema.History.recordType {
            return nil
        }
        guard let id = SyncSchema.History.entryID(fromRecordName: recordName) else {
            return nil
        }
        return .deleted(id)
    }
}

/// Comparison revision ⇄ `ModelComparisonRound` record.
///
/// The round is one JSON payload versioned by `ModelComparisonRound.schemaVersion`;
/// the flat fields exist for ordering and type filtering. Deletions are dated
/// revisions carrying the same flat fields, so offline peers still see them.
enum ComparisonRecordCodec {
    private typealias Field = ComparisonRoundRecordField

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func assignments(for round: ModelComparisonRound) throws -> SyncRecordFieldAssignments {
        guard let payload = String(data: try encoder.encode(round), encoding: .utf8) else {
            throw SyncError.encodingFailed
        }
        return [
            (Field.roundID, .string(round.id.uuidString)),
            (Field.createdAt, .timestamp(round.createdAt)),
            (Field.updatedAt, .timestamp(round.updatedAt)),
            (Field.originPlatform, .string(round.originPlatform)),
            (Field.schemaVersion, .int64(Int64(ModelComparisonRound.schemaVersion))),
            (Field.payload, .string(payload))
        ]
    }

    /// Tombstones use the same payload and flat fields, with no additional schema fields.
    static func assignments(for revision: ModelComparisonRevision) throws -> SyncRecordFieldAssignments {
        if let round = revision.round {
            return try assignments(for: round)
        }
        let payload = String(data: try encoder.encode(revision), encoding: .utf8)
        return [
            (Field.roundID, .string(revision.id.uuidString)),
            (Field.createdAt, .timestamp(revision.updatedAt)),
            (Field.updatedAt, .timestamp(revision.updatedAt)),
            (Field.originPlatform, .string(SyncSchema.ComparisonRound.tombstoneOriginPlatform)),
            (Field.schemaVersion, .int64(Int64(ModelComparisonRound.schemaVersion))),
            (Field.payload, payload.map(SyncFieldValue.string))
        ]
    }

    /// Decodes a round, or `nil` when the record is not a decodable round —
    /// including a payload written by a newer schema this build cannot read,
    /// which is skipped rather than surfaced as a broken round.
    static func round(from record: some SyncRecordFieldReading) -> ModelComparisonRound? {
        guard record.syncRecordType == SyncSchema.ComparisonRound.recordType,
              let payload = record.string(forKey: Field.payload),
              let version = record.int(forKey: Field.schemaVersion),
              version <= ModelComparisonRound.schemaVersion else {
            return nil
        }
        let legacy = JSONDecoder()
        legacy.dateDecodingStrategy = .iso8601
        guard var round = (try? decoder.decode(ModelComparisonRound.self, from: Data(payload.utf8)))
            ?? (try? legacy.decode(ModelComparisonRound.self, from: Data(payload.utf8))),
              round.id == SyncSchema.ComparisonRound.roundID(fromRecordName: record.syncRecordName) else {
            return nil
        }
        // The flat field is the sync ordering authority; the payload copy is
        // kept consistent so a re-upload carries the same value.
        if let updatedAt = record.date(forKey: Field.updatedAt), updatedAt > round.updatedAt {
            round.updatedAt = updatedAt
        }
        return round
    }

    static func revision(from record: some SyncRecordFieldReading) throws -> ModelComparisonRevision {
        guard record.syncRecordType == SyncSchema.ComparisonRound.recordType,
              let version = record.int(forKey: Field.schemaVersion),
              version == ModelComparisonRound.schemaVersion else {
            throw SyncError.decodingFailed
        }
        if let round = round(from: record) {
            return ModelComparisonRevision(round: round)
        }
        // A round this build cannot validate must not be read as a deletion:
        // `ModelComparisonRevision` decodes from any object carrying `id` and
        // `updatedAt`, which every round payload does.
        guard let payload = record.string(forKey: Field.payload),
              !isRoundShaped(Data(payload.utf8)),
              let revision = try? decoder.decode(ModelComparisonRevision.self, from: Data(payload.utf8)),
              revision.isValid, revision.round == nil,
              revision.id == SyncSchema.ComparisonRound.roundID(fromRecordName: record.syncRecordName) else {
            throw SyncError.decodingFailed
        }
        return revision
    }

    /// A changed record's contribution to a comparison fetch. A comparison record
    /// this build cannot read throws, so a compatible build replays the page.
    static func change(from record: some SyncRecordFieldReading) throws -> ComparisonRemoteChange? {
        guard record.syncRecordType == SyncSchema.ComparisonRound.recordType else {
            return nil
        }
        return .revision(try revision(from: record))
    }

    static func deletion(recordName: String, recordType: String?) -> ComparisonRemoteChange? {
        if let recordType, recordType != SyncSchema.ComparisonRound.recordType {
            return nil
        }
        guard let id = SyncSchema.ComparisonRound.roundID(fromRecordName: recordName) else {
            return nil
        }
        return .deleted(id)
    }

    private static func isRoundShaped(_ payload: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        return object["entries"] != nil
    }
}

/// Encrypted API key ⇄ `EncryptedSecret` record.
enum EncryptedSecretRecordCodec {
    private typealias Field = EncryptedSecretRecordField

    static func assignments(for secret: EncryptedSecret) -> SyncRecordFieldAssignments {
        [
            (Field.identifier, .string(secret.identifier)),
            (Field.ciphertext, .bytes(secret.ciphertext)),
            (Field.nonce, .bytes(secret.nonce)),
            (Field.tag, .bytes(secret.tag)),
            (Field.updatedAt, .timestamp(secret.updatedAt)),
            (Field.isDeleted, .int64(secret.isDeleted ? 1 : 0))
        ]
    }

    static func secret(from record: some SyncRecordFieldReading) -> EncryptedSecret? {
        guard record.syncRecordType == SyncSchema.EncryptedSecret.recordType,
              let identifier = record.string(forKey: Field.identifier),
              let ciphertext = record.data(forKey: Field.ciphertext),
              let nonce = record.data(forKey: Field.nonce),
              let tag = record.data(forKey: Field.tag),
              let updatedAt = record.date(forKey: Field.updatedAt) else {
            return nil
        }
        let isDeleted = record.int(forKey: Field.isDeleted) == 1 || record.bool(forKey: Field.isDeleted) == true
        return EncryptedSecret(
            identifier: identifier,
            ciphertext: ciphertext,
            nonce: nonce,
            tag: tag,
            updatedAt: updatedAt,
            isDeleted: isDeleted
        )
    }
}

/// Key-sync salt and verifier ⇄ `EncryptedSecretMetadata` record.
enum KeySyncMetadataRecordCodec {
    private typealias Field = KeySyncMetadataRecordField

    static func assignments(for metadata: KeySyncMetadata, updatedAt: Date) -> SyncRecordFieldAssignments {
        [
            (Field.salt, .bytes(metadata.salt)),
            (Field.verifierNonce, .bytes(metadata.verifierNonce)),
            (Field.verifierCiphertext, .bytes(metadata.verifierCiphertext)),
            (Field.verifierTag, .bytes(metadata.verifierTag)),
            (Field.updatedAt, .timestamp(updatedAt))
        ]
    }

    static func metadata(from record: some SyncRecordFieldReading) -> KeySyncMetadata? {
        guard record.syncRecordType == SyncSchema.KeySyncMetadata.recordType,
              let salt = record.data(forKey: Field.salt),
              let nonce = record.data(forKey: Field.verifierNonce),
              let ciphertext = record.data(forKey: Field.verifierCiphertext),
              let tag = record.data(forKey: Field.verifierTag) else {
            return nil
        }
        return KeySyncMetadata(
            salt: salt,
            verifierNonce: nonce,
            verifierCiphertext: ciphertext,
            verifierTag: tag
        )
    }
}
