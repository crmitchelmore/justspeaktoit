import Foundation
import SpeakCore

@MainActor
extension MigrationStore {

    func collectDefaults(_ snapshot: inout MigrationSnapshot) throws {
        let categories = Set(snapshot.manifest.categories)
        let keys = MigrationCatalog.settingKeys.union(MigrationCatalog.vocabularyKeys)
            .union(MigrationCatalog.connectionKeys).union(MigrationCatalog.credentialDefaults)
        for key in keys.sorted() {
            guard let category = MigrationCatalog.category(for: key), categories.contains(category),
                  let value = defaults.object(forKey: key) else {
                continue
            }
            snapshot.records[category, default: []].append(try MigrationCatalog.defaultsRecord(
                key: key,
                value: value
            ))
        }
    }

    func collectCollections(_ snapshot: inout MigrationSnapshot) throws {
        let categories = Set(snapshot.manifest.categories)
        let scopes = snapshot.manifest.scopes
        for collection in MigrationCatalog.collections where categories.contains(collection.category) {
            let data: Data?
            if let key = collection.defaultsKey {
                data = defaults.data(forKey: key)
            } else if let path = collection.path,
                      FileManager
                      .default
                      .fileExists(atPath: support
                          .appendingPathComponent(
                              path
                          )
                          .path) {
                data = try Data(contentsOf: support.appendingPathComponent(path))
            } else {
                data = nil
            }
            if let data {
                let scope = scopes[collection.category.rawValue] ?? MigrationScope()
                let records = try MigrationCatalog.collectionRecords(collection, data: data)
                    .filter { scope.contains(id: $0.id, date: $0.date) }
                snapshot.records[collection.category, default: []].append(contentsOf: records)
            }
        }
    }

    func collectCredentials(_ snapshot: inout MigrationSnapshot) async throws {
        let categories = Set(snapshot.manifest.categories)
        if categories.contains(.credentials) {
            guard await secrets.preloadAndReportSuccess()
            else {
                throw MigrationError.invalid("Cannot read the credential vault.")
            }
            for id in await secrets.knownIdentifiers() {
                snapshot.records[.credentials, default: []].append(
                    .init(
                        id: id,
                        kind: "secret",
                        value: AnyCodable(.string(try await secrets.secret(identifier: id)))
                    )
                )
            }
        }
    }

    func collectHistory(_ item: HistoryItem, revision: String,
                        into snapshot: inout MigrationSnapshot) throws {
        let categories = Set(snapshot.manifest.categories)
        let scopes = snapshot.manifest.scopes
        if categories.contains(.history), history.item(id: item.id) != nil,
           (scopes["history"] ?? MigrationScope()).contains(
               id: item.id.uuidString,
               date: item.createdAt
           ) {
            snapshot.records[.history, default: []].append(.init(id: item.id.uuidString, kind: "history",
                                                                 value: try item.migrationValue(),
                                                                 date: item.createdAt,
                                                                 revision: revision))
        }
    }

    func collectRecording(
        _ item: HistoryItem,
        revision: String,
        into snapshot: inout MigrationSnapshot
    ) async throws {
        let categories = Set(snapshot.manifest.categories)
        let scopes = snapshot.manifest.scopes
        if categories.contains(.recordings), let url = item.audioFileURL,
           (scopes["recordings"] ?? MigrationScope()).contains(
               id: item.id.uuidString,
               date: item.createdAt
           ) {
            do {
                let digest = try await Task.detached { try MigrationCoding.fileDigest(url) }.value
                let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
                let path = "recordings/\(item.id.uuidString)-\(digest).\(ext)"
                snapshot.records[.recordings, default: []].append(.init(
                    id: item.id.uuidString,
                    kind: "audio",
                    value: try item.migrationValue(audioOnly: true),
                    date: item.createdAt,
                    file: path,
                    digest: digest,
                    revision: revision
                ))
                snapshot.files[path] = url
            } catch {
                snapshot.notices.append("Recordings, \(item.id.uuidString): file unavailable; skipped.")
            }
        }
    }
}
