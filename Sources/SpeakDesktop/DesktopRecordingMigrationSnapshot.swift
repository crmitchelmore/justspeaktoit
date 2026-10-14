import Foundation
import SpeakCore

extension DesktopRecordingStore {
    public func migrationSnapshot(
        categories: Set<DataMigrationCategory>, scopes: [String: DataMigrationScope] = [:],
        excludingAudio filenames: Set<String> = [], digests: LocalModelDigestProvider
    ) throws -> DataMigrationSnapshot {
        guard categories.isSubset(of: [.history, .recordings]) else {
            throw DataMigrationError.invalid("This collector owns only History and recording audio.")
        }
        try Task.checkCancellation()
        try Self.validateMigrationScopeDates(scopes)
        let retained = try records().filter { !filenames.contains($0.audioFilename) }
        let audio = categories.contains(.recordings) ? try snapshotSavedAudio(excluding: filenames) : nil
        let archiveScopes = Self.recordingHistoryScopes(scopes, categories: categories)
        var snapshot = DataMigrationSnapshot(
            manifest: .init(
                categories: DataMigrationCategory.allCases.filter(categories.contains), scopes: archiveScopes
            ),
            records: Dictionary(uniqueKeysWithValues: categories.map { ($0, []) })
        )
        let byFilename = Dictionary(grouping: retained.filter { !$0.audioFilename.isEmpty }, by: \.audioFilename)
        let retainedIDs = Set(retained.map(\.id))
        var standaloneIDs = Set<UUID>()
        if categories.contains(.history) {
            snapshot.records[.history] = try Self.migrationHistory(
                retained, scope: archiveScopes[DataMigrationCategory.history.rawValue] ?? .init(), digests: digests
            )
        }
        let audioScope = archiveScopes[DataMigrationCategory.recordings.rawValue] ?? .init()
        if let audio {
            snapshot.notices = try Self.unavailableMigrationAudio(retained, audio: audio, scope: audioScope)
        }
        for entry in audio?.entries ?? [] {
            try Task.checkCancellation()
            var records = byFilename[entry.filename] ?? []
            if records.isEmpty {
                let id = try Self.migrationStandaloneID(
                    entry.filename, retainedIDs: retainedIDs, standaloneIDs: &standaloneIDs, digests: digests
                )
                records = [Record(id: id, audioFilename: entry.filename, modelIdentifier: "",
                                  createdAt: entry.identity.created ?? .distantPast)]
            }
            records = records.filter { audioScope.contains(id: $0.id.uuidString, date: $0.createdAt, kind: "audio") }
            guard let first = records.first else { continue }
            let url = try ownedAudioURL(for: first)
            let digest = try Self.migrationAudioDigest(url, identity: entry.identity, digests: digests)
            for record in records {
                let audioRecord = try Self.migrationAudioRecord(record, url: url, digest: digest, digests: digests)
                snapshot.records[.recordings, default: []].append(audioRecord.record)
                snapshot.files[audioRecord.path] = url
            }
        }
        try Task.checkCancellation()
        return snapshot
    }

    private static func recordingHistoryScopes(
        _ scopes: [String: DataMigrationScope], categories: Set<DataMigrationCategory>
    ) -> [String: DataMigrationScope] {
        guard categories.contains(.history) else { return scopes }
        var result = scopes
        var history = result[DataMigrationCategory.history.rawValue] ?? .init()
        history.selectedKinds = history.selectedKinds.map { $0.intersection(["history"]) } ?? ["history"]
        result[DataMigrationCategory.history.rawValue] = history
        return result
    }

    private static func migrationAudioRecord(
        _ record: Record, url: URL, digest: String, digests: LocalModelDigestProvider
    ) throws -> (record: DataMigrationRecord, path: String) {
        try Task.checkCancellation()
        let value = try DesktopMigrationHistory.value(record)
        let path = "recordings/\(record.id.uuidString)-\(digest).\(url.pathExtension.lowercased())"
        let revision = try digests.sha256(of: DataMigrationCoding.encoder.encode(value))
        return (.init(
            id: record.id.uuidString, kind: "audio", value: try DataMigrationHistoryValue.value(value, audioOnly: true),
            date: try migrationDate(record.createdAt), file: path, digest: digest, revision: revision
        ), path)
    }

    private static func migrationHistory(
        _ records: [Record], scope: DataMigrationScope, digests: LocalModelDigestProvider
    ) throws -> [DataMigrationRecord] {
        var history: [DataMigrationRecord] = []
        for record in records {
            try Task.checkCancellation()
            guard scope.contains(id: record.id.uuidString, date: record.createdAt, kind: "history") else { continue }
            let value = try DesktopMigrationHistory.value(record)
            history.append(.init(
                id: record.id.uuidString, kind: "history", value: value, date: try migrationDate(record.createdAt),
                revision: try digests.sha256(of: DataMigrationCoding.encoder.encode(value))
            ))
        }
        return history
    }

    private static func migrationDate(_ date: Date) throws -> Date {
        try DataMigrationCoding.decode(Date.self, DataMigrationCoding.value(date))
    }

    private static func validateMigrationScopeDates(_ scopes: [String: DataMigrationScope]) throws {
        for scope in scopes.values {
            for boundary in [scope.start, scope.end].compactMap({ $0 }) {
                guard try migrationDate(boundary) == boundary else {
                    throw DataMigrationError.invalid("Archive date scopes require whole-second boundaries.")
                }
            }
        }
    }

    private static func unavailableMigrationAudio(
        _ records: [Record], audio: DesktopRecordingAudioSnapshot, scope: DataMigrationScope
    ) throws -> [String] {
        let available = Set(audio.entries.map(\.filename))
        var notices: [String] = []
        for record in records where !record.audioFilename.isEmpty && !available.contains(record.audioFilename) {
            try Task.checkCancellation()
            guard scope.contains(id: record.id.uuidString, date: record.createdAt, kind: "audio") else { continue }
            notices.append("Recordings, \(record.id.uuidString): file unavailable; skipped.")
        }
        return notices
    }

    private static func migrationStandaloneID(
        _ filename: String, retainedIDs: Set<UUID>, standaloneIDs: inout Set<UUID>, digests: LocalModelDigestProvider
    ) throws -> UUID {
        let identifier = try DataMigrationPlanner.variantID(
            id: "standalone-recording", revision: filename, digest: digests.sha256(of:)
        )
        guard let id = UUID(uuidString: identifier) else {
            throw DataMigrationError.invalid("Invalid standalone recording identifier")
        }
        guard !retainedIDs.contains(id), standaloneIDs.insert(id).inserted else {
            throw DataMigrationError.invalid("Conflicting standalone recording identifier")
        }
        return id
    }

    private static func migrationAudioDigest(
        _ url: URL, identity: DesktopRecordingAudioSnapshot.Identity, digests: LocalModelDigestProvider
    ) throws -> String {
        guard try audioCleanupIdentity(at: url) == identity else { throw DesktopRecordingAudioCleanupError.changedFile }
        let digest = try digests.sha256(ofFileAt: url)
        guard try audioCleanupIdentity(at: url) == identity else { throw DesktopRecordingAudioCleanupError.changedFile }
        return digest
    }
}
