import Foundation
import SpeakCore

/// The CloudKit schema every client of the existing Apple data uses.
///
/// Record types, field names, value types and record names here are the
/// production format written by shipped iOS and Mac App Store builds. The
/// native `CKRecord` adapters and the CloudKit Web Services transport both read
/// them from this one definition. Changing an entry is a schema migration for
/// every installed client, not a refactor.
///
/// All four record types share one custom zone. Record names are disjoint:
/// History uses a bare UUID, Compare Models rounds use `comparison-<UUID>`,
/// encrypted secrets use `secret-<base64url>` and the key-sync metadata record
/// has a fixed name. When a change feed omits the type of a deleted record,
/// that naming is what identifies it, so a new record type must not reuse any
/// of these shapes.
public enum SyncSchema {
    /// The private-database custom zone shared by every synced record type.
    public static let zoneName = "TranscriptionHistoryZone"

    /// Maximum number of entries to sync in a single batch.
    public static let batchSize = 100

    /// Transcription History entries; fields are `HistoryRecordField`.
    public enum History {
        public static let recordType = "TranscriptionHistory"
        /// The database subscription whose pushes announce a history change.
        public static let subscriptionID = "transcription-history-changes"

        public static func recordName(for entryID: UUID) -> String {
            entryID.uuidString
        }

        public static func entryID(fromRecordName name: String) -> UUID? {
            UUID(uuidString: name)
        }
    }

    /// Compare Models rounds (issue #1101), stored as a versioned JSON payload;
    /// fields are `ComparisonRoundRecordField`.
    public enum ComparisonRound {
        public static let recordType = "ModelComparisonRound"
        static let recordNamePrefix = "comparison-"
        /// Origin written on a deletion revision. Existing tombstones carry this
        /// value, so every writer keeps it rather than naming its own platform.
        static let tombstoneOriginPlatform = "macos"

        public static func recordName(for roundID: UUID) -> String {
            recordNamePrefix + roundID.uuidString
        }

        /// The round id a record name encodes, or `nil` for other record names.
        public static func roundID(fromRecordName name: String) -> UUID? {
            guard name.hasPrefix(recordNamePrefix) else { return nil }
            return UUID(uuidString: String(name.dropFirst(recordNamePrefix.count)))
        }
    }

    /// Passphrase-encrypted API keys (`CloudKitKeySync`); fields are
    /// `EncryptedSecretRecordField`.
    public enum EncryptedSecret {
        public static let recordType = "EncryptedSecret"
        public static let subscriptionID = "encrypted-secret-changes"
        static let recordNamePrefix = "secret-"

        /// The canonical, bounded set of credential identifiers API-key sync
        /// carries. Every client reads this one list: the Apple engine uploads
        /// and applies only these, and a desktop client imports only these.
        /// Other credentials never leave the device they were entered on.
        public static let syncableIdentifiers: Set<String> = [
            "deepgram.apiKey",
            "openai.apiKey",
            "openrouter.apiKey",
            "elevenlabs.apiKey",
            "cartesia.apiKey",
            "assemblyai.apiKey",
            "gladia.apiKey",
            "google.apiKey",
            "modulate.apiKey",
            "soniox.apiKey",
            "xai.apiKey",
            "meta.apiKey"
        ]

        /// `secret-` followed by the identifier's UTF-8 bytes in unpadded base64url.
        public static func recordName(for identifier: String) -> String {
            let encoded = Data(identifier.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return recordNamePrefix + encoded
        }

        /// The credential identifier a record name encodes, or `nil` for other names.
        public static func identifier(fromRecordName name: String) -> String? {
            guard name.hasPrefix(recordNamePrefix) else { return nil }
            var encoded = String(name.dropFirst(recordNamePrefix.count))
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while encoded.count % 4 != 0 { encoded.append("=") }
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// The single record holding the key-sync salt and passphrase verifier;
    /// fields are `KeySyncMetadataRecordField`.
    public enum KeySyncMetadata {
        public static let recordType = "EncryptedSecretMetadata"
        public static let recordName = "api-key-sync-metadata"
    }
}

enum HistoryRecordField {
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

enum ComparisonRoundRecordField {
    static let roundID = "roundID"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"
    static let originPlatform = "originPlatform"
    static let schemaVersion = "schemaVersion"
    static let payload = "payload"
}

enum EncryptedSecretRecordField {
    static let identifier = "identifier"
    static let ciphertext = "ciphertext"
    static let nonce = "nonce"
    static let tag = "tag"
    static let updatedAt = "updatedAt"
    static let isDeleted = "isDeleted"
}

enum KeySyncMetadataRecordField {
    static let salt = "salt"
    static let verifierNonce = "verifierNonce"
    static let verifierCiphertext = "verifierCiphertext"
    static let verifierTag = "verifierTag"
    static let updatedAt = "updatedAt"
}

/// The two existing CloudKit containers. iOS and macOS use different
/// containers, so History syncs within a platform family and never across it
/// (see `Docs/Architecture.md`). A client joins one family explicitly;
/// consolidating them would be a data migration, which no client performs.
public enum SyncContainerFamily: String, CaseIterable, Sendable {
    /// Mac App Store History, Compare Models rounds and encrypted API keys.
    case macOS
    /// iPhone and iPad History and encrypted API keys.
    case iOS

    /// The container identifier for this family in a release train, read from
    /// the canonical `ReleaseTrains.json` catalogue.
    public func containerIdentifier(in train: ReleaseTrain) -> String {
        switch self {
        case .macOS: return train.macCloudContainer
        case .iOS: return train.iosCloudContainer
        }
    }

    /// Whether this family's clients write Compare Models rounds. Only the Mac
    /// App Store build has a comparison sync adapter today.
    public var carriesComparisonRounds: Bool { self == .macOS }
}
