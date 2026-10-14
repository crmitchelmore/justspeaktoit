import Foundation
import SpeakCore

extension DesktopMigrationBackup {
    /// Call from an owned off-actor worker: archive/publication perform
    /// synchronous native I/O and observe this task's cancellation.
    public static func export(
        store: DesktopRecordingStore, destination: URL, includeAudio: Bool, adapter: Adapter
    ) async -> Outcome {
        var staging: URL?
        var outcome: Outcome
        do {
            try Task.checkCancellation()
            let categories: Set<DataMigrationCategory> = includeAudio ? [.history, .recordings] : [.history]
            let snapshot = try await store.migrationSnapshot(categories: categories, digests: adapter.digests)
            try Task.checkCancellation()
            let file = try adapter.archive(snapshot)
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
}
