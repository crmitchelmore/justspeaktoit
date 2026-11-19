import Foundation
import SpeakCore

extension DesktopMigrationBackup {
    /// Call from an owned off-actor worker: archive/publication perform
    /// synchronous native I/O and observe this task's cancellation.
    public static func export(
        store: DesktopRecordingStore, destination: URL, includeAudio: Bool, adapter: Adapter
    ) async -> Outcome {
        await export(
            store: store, destination: destination, includeAudio: includeAudio, profiles: nil, adapter: adapter
        )
    }

    public static func export(
        store: DesktopRecordingStore, destination: URL, includeAudio: Bool,
        profiles: DesktopDictationProfileStore?, adapter: Adapter
    ) async -> Outcome {
        await export(
            store: store, destination: destination,
            contents: .init(includeAudio: includeAudio, profiles: profiles), adapter: adapter
        )
    }

    /// API keys are written only when `contents.configuration` supplies a credential reader.
    public static func export(
        store: DesktopRecordingStore, destination: URL, contents: Contents, adapter: Adapter
    ) async -> Outcome {
        var staging: URL?
        var outcome: Outcome
        do {
            try Task.checkCancellation()
            let categories: Set<DataMigrationCategory> = contents.includeAudio
                ? [.history, .recordings] : [.history]
            var snapshot = try await store.migrationSnapshot(categories: categories, digests: adapter.digests)
            if let profiles = contents.profiles {
                let profileSnapshot = try profiles.migrationSnapshot(digests: adapter.digests)
                snapshot.manifest.categories.append(.profiles)
                snapshot.manifest.scopes.merge(profileSnapshot.manifest.scopes) { _, profile in profile }
                snapshot.records[.profiles] = profileSnapshot.records[.profiles]
            }
            if let configuration = contents.configuration {
                try add(configuration, to: &snapshot, digests: adapter.digests)
            }
            try Task.checkCancellation()
            let file = try adapter.archive(snapshot, snapshot.manifest.categories.contains(.credentials))
            try DesktopMigrationStaging.requireLocalFile(file)
            guard file.lastPathComponent == "export.zip" else {
                throw DataMigrationError.invalid("The archive producer returned an invalid owned staging path.")
            }
            staging = try DesktopMigrationStaging.directory(
                file.deletingLastPathComponent(), prefix: "migration-export-"
            )
            try Task.checkCancellation()
            try adapter.publish(file, destination)
            outcome = .saved
        } catch let failure as DesktopFilePublication.CopyCompletionFailure {
            outcome = .savedWithWarning(failure.localizedDescription)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        if let staging {
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                outcome = outcome.addingCleanupFailure(error.localizedDescription)
            }
        }
        return outcome
    }

    static func add(
        _ configuration: Configuration, to snapshot: inout DataMigrationSnapshot, digests: LocalModelDigestProvider
    ) throws {
        var categories = Set(snapshot.manifest.categories)
        for (category, records) in configuration.records {
            guard ![.history, .recordings, .profiles, .credentials].contains(category) else {
                throw DataMigrationError.invalid("\(category.title) cannot be added as configuration.")
            }
            categories.insert(category)
            snapshot.records[category, default: []] += records
        }
        if let directory = configuration.vocabularyDirectory {
            let collections = try DesktopVocabularyMigrationSnapshot.collect(appDirectory: directory, digests: digests)
            categories.insert(.vocabulary)
            snapshot.records[.vocabulary, default: []] += collections.flatMap { $0.records ?? [] }
        }
        if let credentials = configuration.credentials {
            try Task.checkCancellation()
            let records = try credentials()
            if !records.isEmpty {
                categories.insert(.credentials)
                snapshot.records[.credentials] = records
            }
        }
        snapshot.notices += configuration.notices
        snapshot.manifest.categories = DataMigrationCategory.allCases.filter(categories.contains)
    }
}
