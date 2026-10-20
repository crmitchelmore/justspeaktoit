import Foundation
import SpeakDesktop

extension DesktopHostPlatform {
    package static var migrationArchive: DesktopMigrationBackup.Adapter? { nil }
}

extension DesktopHostController {
    /// Admission only: native settings queues must never wait for archive I/O.
    package func beginMigrationExport(
        _ destination: URL, includeAudio: Bool, using adapter: DesktopMigrationBackup.Adapter? = nil
    ) {
        beginMigrationExport(
            destination, selection: .init(includeAudio: includeAudio), using: adapter
        )
    }

    package func beginMigrationExport(_ destination: URL, nativeFlags: Int) {
        do {
            beginMigrationExport(destination, selection: try .init(nativeFlags: nativeFlags))
        } catch {
            update("Could not save backup: \(error.localizedDescription)")
        }
    }

    package func beginMigrationExport(
        _ destination: URL, selection: DesktopMigrationBackup.Selection,
        using adapter: DesktopMigrationBackup.Adapter? = nil
    ) {
        guard !closed else { return }
        guard canUseHistory, migrationExportTask == nil, audioCleanupConfirmation == nil else {
            let state: Int32
            if busy { state = 2 } else if recording != nil { state = 1 } else { state = 0 }
            update("History backup is unavailable while another operation or confirmation is running.", state: state)
            return
        }
        guard let adapter = adapter ?? Platform.migrationArchive else {
            update("History backup is unavailable on this host.")
            return
        }
        if selection.includeProfiles, let profileWarning {
            update("App profiles cannot be backed up until their unreadable source is recovered. \(profileWarning)")
            return
        }
        busy = true
        cancellationRequested = false
        activeOperations += 1
        update("Exporting \(selection.description)...", state: 2)
        let store = store
        let profiles = selection.includeProfiles ? profileStore : nil
        let worker = Task.detached {
            await DesktopMigrationBackup.export(
                store: store, destination: destination, includeAudio: selection.includeAudio,
                profiles: profiles, adapter: adapter
            )
        }
        migrationExportWorker = worker
        migrationExportTask = Task {
            let outcome = await worker.value
            defer {
                migrationExportWorker = nil
                migrationExportTask = nil
                busy = false
                finishOperation()
            }
            guard !closed else { return }
            showSelectedHistory(
                status: migrationExportStatus(outcome, selection: selection, destination: destination), state: 0
            )
        }
    }

    private func migrationExportStatus(
        _ outcome: DesktopMigrationBackup.Outcome, selection: DesktopMigrationBackup.Selection, destination: URL
    ) -> String {
        let description = selection.description
        switch outcome {
        case .saved:
            return "Saved \(description) backup as \(destination.lastPathComponent)."
        case let .savedWithWarning(warning):
            return "Saved \(description) backup as \(destination.lastPathComponent). \(warning)"
        case .cancelled:
            let name = selection.includeProfiles ? "Backup" : "History backup"
            return "\(name) cancelled. No destination was published; existing files were kept."
        case let .failed(message):
            let name = selection.includeProfiles ? "backup" : "History backup"
            return "Could not save \(name): \(message)"
        }
    }
}
