import Foundation
import SpeakCore

/// Raw owned-source evidence for the canonical Mac collections, never a runtime/editor snapshot.
public enum DesktopVocabularyArchiveSource {
    public struct Collection: Sendable {
        public let definition: DataMigrationVocabularyCatalog.Collection
        public let source: DesktopOwnedAppDataFileReader.StrictSnapshot
        /// Nil is anchored source absence; [] is an existing empty collection.
        public let records: [DataMigrationRecord]?
    }

    public struct PartialProjection: Sendable {
        public let records: [DataMigrationRecord]
        public let scope: DataMigrationScope
        public let selectedKinds: Set<String>
        public var isCompleteCategory: Bool { false }
    }

    public struct Snapshot: Sendable {
        public let collections: [Collection]
        /// No Mac wire kind exists for this native preference composite.
        public let unmappedPreferences: DesktopOwnedAppDataFileReader.StrictSnapshot
        public var isCompleteCategory: Bool { false }

        /// Explicit compatible-kind projection only, never complete-category export authority.
        /// Unmapped preferences stay in this snapshot, off the Mac record/apply route.
        /// Version 1 does not encode each collection's absent-versus-empty source state.
        public func projectCompatibleKinds(
            scope: DataMigrationScope = .init(),
            checkCancellation: () throws -> Void = { try Task.checkCancellation() }
        ) throws -> PartialProjection {
            try checkCancellation()
            var records: [DataMigrationRecord] = []
            for collection in collections {
                for record in collection.records ?? [] {
                    try checkCancellation()
                    if scope.contains(id: record.id, date: record.date) { records.append(record) }
                }
            }
            try Self.requireRecordBudget(records)
            try revalidate(checkCancellation: checkCancellation)
            let partialScope = DataMigrationScope(
                start: scope.start, end: scope.end,
                selectedIDs: scope.selectedIDs ?? Set(records.map(\.id))
            )
            return PartialProjection(
                records: records, scope: partialScope, selectedKinds: Set(collections.map(\.definition.kind))
            )
        }

        /// Point-in-time revalidation, not a multi-store atomic snapshot, CAS or write authority.
        public func revalidate(
            checkCancellation: () throws -> Void = { try Task.checkCancellation() }
        ) throws {
            try checkCancellation()
            for collection in collections {
                try DesktopOwnedAppDataFileReader.revalidateStrict(
                    collection.source.receipt, checkCancellation: checkCancellation
                )
            }
            try DesktopOwnedAppDataFileReader.revalidateStrict(
                unmappedPreferences.receipt, checkCancellation: checkCancellation
            )
            try checkCancellation()
        }

        fileprivate static func requireRecordBudget(_ records: [DataMigrationRecord]) throws {
            guard UInt64(try DataMigrationCoding.encoder.encode(records).count)
                <= DataMigrationArchivePolicy.maximumJSONBytes else {
                throw DataMigrationError.invalid("Vocabulary records exceed the category JSON size limit.")
            }
        }
    }

    /// Uses the caller's already-owned root. Missing or insufficient root identity is an error.
    public static func collect(
        appDirectory: URL, digests: LocalModelDigestProvider,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Snapshot {
        try checkCancellation()
        var bytes: UInt64 = 0
        var sources: [(DataMigrationVocabularyCatalog.Collection, DesktopOwnedAppDataFileReader.StrictSnapshot)] = []
        for definition in DataMigrationVocabularyCatalog.collections {
            let source = try read(
                definition.desktopPath, root: appDirectory, bytes: &bytes, checkCancellation: checkCancellation
            )
            sources.append((definition, source))
        }
        let unmapped = try read(
            DesktopVocabularyMigrationSnapshot.unmappedPreferencePath,
            root: appDirectory, bytes: &bytes, checkCancellation: checkCancellation
        )
        if let data = unmapped.data {
            try checkCancellation()
            _ = try JSONDecoder().decode(DesktopVocabularyPreferences.self, from: data)
        }
        var collections: [Collection] = []
        var identities = Set<String>()
        for (definition, source) in sources {
            try checkCancellation()
            var records: [DataMigrationRecord]?
            if let data = source.data {
                records = try DataMigrationVocabularyCatalog.records(
                    data: data, kind: definition.kind, digest: digests.sha256(of:),
                    checkCancellation: checkCancellation
                )
                for record in records ?? [] {
                    try checkCancellation()
                    try DataMigrationVocabularyCatalog.validate(record, category: .vocabulary)
                    guard identities.insert(record.identity).inserted else {
                        throw DataMigrationError.invalid("Duplicate vocabulary entry identifier.")
                    }
                }
            }
            collections.append(Collection(definition: definition, source: source, records: records))
        }
        try checkCancellation()
        try Snapshot.requireRecordBudget(collections.flatMap { $0.records ?? [] })
        let result = Snapshot(collections: collections, unmappedPreferences: unmapped)
        try result.revalidate(checkCancellation: checkCancellation)
        return result
    }

    private static func read(
        _ path: String, root: URL, bytes: inout UInt64, checkCancellation: () throws -> Void
    ) throws -> DesktopOwnedAppDataFileReader.StrictSnapshot {
        try checkCancellation()
        let source = try DesktopOwnedAppDataFileReader.readStrict(
            path, appDirectory: root, maximumBytes: DataMigrationArchivePolicy.maximumJSONBytes - bytes,
            checkCancellation: checkCancellation
        )
        bytes += UInt64(source.data?.count ?? 0)
        return source
    }
}
