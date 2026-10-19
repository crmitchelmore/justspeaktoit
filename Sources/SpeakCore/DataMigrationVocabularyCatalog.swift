import Foundation

/// Version-1 Mac collection contracts, shared without projecting away raw payload fields.
public enum DataMigrationVocabularyCatalog {
    public struct Collection: Equatable, Sendable {
        public let kind: String
        public let defaultsKey: String?
        public let path: String?
        public let desktopPath: String
    }

    public static let collections: [Collection] = [
        .init(
            kind: "pronunciation", defaultsKey: "pronunciationDictionary", path: nil,
            desktopPath: "pronunciation.json"
        ),
        .init(
            kind: "lexicon", defaultsKey: nil, path: "PersonalLexicon/lexicon.json",
            desktopPath: "PersonalLexicon/lexicon.json"
        ),
        .init(
            kind: "correction", defaultsKey: nil, path: "AutoCorrections/candidates.json",
            desktopPath: "AutoCorrections/candidates.json"
        )
    ]

    /// Preserves the original payload, array order and Mac timestamp/identity projection.
    public static func records(
        data: Data, kind: String, digest: (Data) throws -> String,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [DataMigrationRecord] {
        try checkCancellation()
        guard collections.contains(where: { $0.kind == kind }) else {
            throw DataMigrationError.invalid("Unknown vocabulary collection.")
        }
        return try DataMigrationCollectionRecords.records(
            data: data, kind: kind, digest: digest, checkCancellation: checkCancellation
        )
    }

    /// Typed decoding validates the Mac contract but never replaces the opaque record value.
    public static func validate(_ record: DataMigrationRecord, category: DataMigrationCategory) throws {
        guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.id.count < 1024 else {
            throw DataMigrationError.invalid("Invalid identifier")
        }
        guard category == .vocabulary, collections.contains(where: { $0.kind == record.kind }) else {
            throw DataMigrationError.invalid("Unknown item type")
        }
        if let object = record.value.value as? [String: Any], let id = object["id"] as? String, id != record.id {
            throw DataMigrationError.invalid("Mismatched item identifier")
        }
        switch record.kind {
        case "pronunciation":
            _ = try JSONDecoder().decode(PronunciationEntry.self, from: JSONEncoder().encode(record.value))
        case "lexicon":
            _ = try DataMigrationCoding.decode(PersonalLexiconRule.self, record.value)
        case "correction":
            _ = try DataMigrationCoding.decode(AutoCorrectionCandidate.self, record.value)
        default:
            throw DataMigrationError.invalid("Unknown collection")
        }
    }
}
