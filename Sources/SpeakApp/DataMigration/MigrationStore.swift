import Foundation
import SpeakCore

@MainActor
final class MigrationStore {
    let defaults: UserDefaults
    let support: URL
    let history: HistoryManager
    let secrets: SecureStorage

    init(
        defaults: UserDefaults = .standard,
        support: URL? = nil,
        history: HistoryManager,
        secrets: SecureStorage
    ) {
        self.defaults = defaults
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask)[0].appendingPathComponent(
            "SpeakApp"
        )
        self.history = history
        self.secrets = secrets
    }

    func snapshot(categories: Set<MigrationCategory>,
                  scopes: [String: MigrationScope] = [:]) async throws -> MigrationSnapshot {
        await history.waitUntilLoaded()
        guard history.loadState.isReady
        else {
            throw MigrationError.invalid("History must finish loading before migration.")
        }
        var snapshot = MigrationSnapshot(
            manifest: .init(categories: MigrationCategory.allCases.filter(categories.contains),
                            scopes: scopes),
            records: [:]
        )
        for category in categories { snapshot.records[category] = [] }
        try collectDefaults(&snapshot)
        try collectCollections(&snapshot)
        try await collectCredentials(&snapshot)
        if categories.contains(.models) {
            try addInstalledModelReferences(to: &snapshot)
        }
        let recordingItems = categories.contains(.recordings) ? try self.recordingItems() : []
        let all = history.allItems + recordingItems
            .filter { audio in !history.allItems.contains { $0.id == audio.id } }
        for item in all {
            let revision = MigrationCoding.digest(try MigrationCoding.encoder.encode(item.migrationValue()))
            try collectHistory(item, revision: revision, into: &snapshot)
            try await collectRecording(item, revision: revision, into: &snapshot)
        }
        return snapshot
    }

    func validate(_ incoming: MigrationSnapshot) -> MigrationSnapshot {
        var validated = incoming
        for category in incoming.manifest.categories {
            guard let records = incoming.records[category] else {
                continue
            }
            validated.records[category] = records.filter { record in
                do {
                    try MigrationCatalog.validate(record, category: category)
                    if category == .history || category == .recordings {
                        let scope = incoming.manifest.scopes[category.rawValue] ?? MigrationScope()
                        guard scope.contains(id: record.id, date: record.date) else {
                            throw MigrationError.invalid("Item is outside the exported selection")
                        }
                    }
                    return true
                } catch {
                    validated.notices
                        .append("\(category.title), \(record.id): skipped invalid or unsupported item.")
                    return false
                }
            }
        }
        return validated
    }

    func apply(_ snapshot: MigrationSnapshot, categories: Set<MigrationCategory>) async throws {
        for category in categories {
            let records = snapshot.records[category] ?? []
            try applyDefaults(records, category: category)
            try applyCollections(records, category: category)
            try await applyCredentials(records, category: category)
        }
        if categories.contains(.history) || categories.contains(.recordings) {
            try await applyHistory(snapshot, categories: categories)
        }
        guard defaults.synchronize() else {
            throw MigrationError.invalid("Preferences could not be saved.")
        }
    }

    private func applyDefaults(_ records: [MigrationRecord], category: MigrationCategory) throws {
        let keys = MigrationCatalog.settingKeys.union(MigrationCatalog.vocabularyKeys)
            .union(MigrationCatalog.connectionKeys).union(MigrationCatalog.credentialDefaults)
            .filter { MigrationCatalog.category(for: $0) == category }
        for key in keys {
            if let record = records
                .first(where: { $0.id == key && ["default", "jsonDefault"].contains($0.kind) }) {
                let value: Any = record.kind == "jsonDefault" ? try JSONEncoder()
                    .encode(record.value) : record.value.value
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func applyCollections(_ records: [MigrationRecord], category: MigrationCategory) throws {
        for collection in MigrationCatalog.collections where collection.category == category {
            let values = records.filter { $0.kind == collection.kind }.map(\.value)
            let data = try JSONEncoder().encode(values)
            if let key = collection.defaultsKey {
                defaults.set(data, forKey: key)
            }
            if let path = collection.path {
                let url = support.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            }
        }
    }

    private func applyCredentials(_ records: [MigrationRecord], category: MigrationCategory) async throws {
        if category == .credentials {
            let credentials = records.filter { $0.kind == "secret" }
            for id in await secrets.knownIdentifiers()
                where !credentials.contains(where: { $0.id == id }) {
                try await secrets.removeSecret(identifier: id)
            }
            for record in credentials {
                guard let value = record.value.value as? String else {
                    continue
                }
                try await secrets.storeSecret(value, identifier: record.id)
            }
        }
    }

    private func applyHistory(_ snapshot: MigrationSnapshot,
                              categories: Set<MigrationCategory>) async throws {
        let text = snapshot.records[.history, default: []].filter { $0.kind == "history" }
        let audio = snapshot.records[.recordings, default: []].filter { $0.kind == "audio" }
        var result: [UUID: HistoryItem] = [:]
        let old = Dictionary(uniqueKeysWithValues: history.allItems.map { ($0.id.uuidString, $0) })
        let ids = Set(text.map(\.id)).union(audio.map(\.id))
        let folder = support.appendingPathComponent("ImportedRecordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in ids {
            let textRecord = text.first { $0.id == id }
            let audioRecord = audio.first { $0.id == id }
            guard let base = textRecord ?? audioRecord else {
                continue
            }
            var item = try MigrationCoding.decode(HistoryItem.self, base.value)
            var audioURL: URL?
            if !categories.contains(.recordings) {
                audioURL = old[id]?.audioFileURL
            } else if let audioRecord, let path = audioRecord.file, let source = snapshot.files[path],
                      let digest = audioRecord.digest {
                let destination = folder
                    .appendingPathComponent("\(id)-\(digest).\((path as NSString).pathExtension)")
                if let existing = old[id]?.audioFileURL, existing == source {
                    audioURL = existing
                } else {
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try await Task
                            .detached { try FileManager.default.copyItem(at: source, to: destination) }
                            .value
                    }
                    audioURL = destination
                }
            }
            item = try MigrationCoding.decode(
                HistoryItem.self,
                item.migrationValue(audioURL: audioURL, id: id)
            )
            result[item.id] = item
        }
        try await history.applyMigrationSnapshot(Array(result.values))
    }
}
