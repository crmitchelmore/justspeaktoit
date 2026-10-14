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
        let retained = try records().filter { !filenames.contains($0.audioFilename) }
        let audio = categories.contains(.recordings) ? try snapshotSavedAudio(excluding: filenames) : nil
        var snapshot = DataMigrationSnapshot(
            manifest: .init(categories: DataMigrationCategory.allCases.filter(categories.contains), scopes: scopes),
            records: Dictionary(uniqueKeysWithValues: categories.map { ($0, []) })
        )
        let byFilename = Dictionary(grouping: retained.filter { !$0.audioFilename.isEmpty }, by: \.audioFilename)
        let retainedIDs = Set(retained.map(\.id))
        var standaloneIDs = Set<UUID>()
        if categories.contains(.history) {
            snapshot.records[.history] = try Self.migrationHistory(
                retained, scope: scopes[DataMigrationCategory.history.rawValue] ?? .init(), digests: digests
            )
        }
        let audioScope = scopes[DataMigrationCategory.recordings.rawValue] ?? .init()
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
            records = records.filter { audioScope.contains(id: $0.id.uuidString, date: $0.createdAt) }
            guard let first = records.first else { continue }
            let url = try ownedAudioURL(for: first)
            let digest = try Self.migrationAudioDigest(url, identity: entry.identity, digests: digests)
            for record in records {
                let value = try DesktopMigrationHistory.value(record)
                let path = "recordings/\(record.id.uuidString)-\(digest).\(url.pathExtension.lowercased())"
                let revision = try digests.sha256(of: DataMigrationCoding.encoder.encode(value))
                snapshot.records[.recordings, default: []].append(.init(
                    id: record.id.uuidString, kind: "audio",
                    value: try DataMigrationHistoryValue.value(value, audioOnly: true), date: record.createdAt,
                    file: path, digest: digest, revision: revision
                ))
                snapshot.files[path] = url
            }
        }
        try Task.checkCancellation()
        return snapshot
    }

    private static func migrationHistory(
        _ records: [Record], scope: DataMigrationScope, digests: LocalModelDigestProvider
    ) throws -> [DataMigrationRecord] {
        var history: [DataMigrationRecord] = []
        for record in records {
            try Task.checkCancellation()
            guard scope.contains(id: record.id.uuidString, date: record.createdAt) else { continue }
            let value = try DesktopMigrationHistory.value(record)
            history.append(.init(
                id: record.id.uuidString, kind: "history", value: value, date: record.createdAt,
                revision: try digests.sha256(of: DataMigrationCoding.encoder.encode(value))
            ))
        }
        return history
    }

    private static func unavailableMigrationAudio(
        _ records: [Record], audio: DesktopRecordingAudioSnapshot, scope: DataMigrationScope
    ) throws -> [String] {
        let available = Set(audio.entries.map(\.filename))
        var notices: [String] = []
        for record in records where !record.audioFilename.isEmpty && !available.contains(record.audioFilename) {
            try Task.checkCancellation()
            guard scope.contains(id: record.id.uuidString, date: record.createdAt) else { continue }
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
