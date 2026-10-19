import Foundation
import SpeakCore

/// Collects owned raw stores, not filtered domain snapshots or native editor strings.
public enum DesktopVocabularyMigrationSnapshot {
    public struct Collection: Sendable {
        public let definition: DataMigrationVocabularyCatalog.Collection
        /// Nil means the source is missing; an empty array means an existing empty JSON array.
        public let records: [DataMigrationRecord]?
    }

    /// This native preference composite has no Mac collection kind and is not collected here.
    public static let unmappedPreferencePath = "vocabulary.json"

    /// Run on an owned cancellable worker while the host suspends store mutation/admission.
    /// Per-file identity checks do not make this a multi-store atomic snapshot.
    public static func collect(
        appDirectory: URL, digests: LocalModelDigestProvider,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [Collection] {
        try checkCancellation()
        guard appDirectory.isFileURL, !appDirectory.path.utf8.contains(0) else {
            throw DataMigrationError.invalid("Vocabulary migration requires an owned local application directory.")
        }
        let root = appDirectory.standardizedFileURL
        var bytes: UInt64 = 0
        var result: [Collection] = []
        for definition in DataMigrationVocabularyCatalog.collections {
            try checkCancellation()
            guard let data = try DesktopVocabularyMigrationSource.read(
                definition.desktopPath, root: root, checkCancellation: checkCancellation
            ) else {
                result.append(.init(definition: definition, records: nil))
                continue
            }
            bytes += UInt64(data.count)
            guard bytes <= DataMigrationArchivePolicy.maximumJSONBytes else {
                throw DataMigrationError.invalid("Vocabulary stores exceed the category JSON size limit.")
            }
            let records = try DataMigrationVocabularyCatalog.records(
                data: data, kind: definition.kind, digest: digests.sha256(of:),
                checkCancellation: checkCancellation
            )
            for record in records {
                try checkCancellation()
                try DataMigrationVocabularyCatalog.validate(record, category: .vocabulary)
            }
            result.append(.init(definition: definition, records: records))
        }
        try checkCancellation()
        let records = result.flatMap { $0.records ?? [] }
        guard UInt64(try DataMigrationCoding.encoder.encode(records).count)
            <= DataMigrationArchivePolicy.maximumJSONBytes else {
            throw DataMigrationError.invalid("Vocabulary records exceed the category JSON size limit.")
        }
        try checkCancellation()
        return result
    }
}
