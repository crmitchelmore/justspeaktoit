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
        busy = true
        cancellationRequested = false
        activeOperations += 1
        update(includeAudio ? "Exporting History and saved recording audio..." : "Exporting History text...", state: 2)
        let store = store
        let worker = Task.detached {
            await DesktopMigrationBackup.export(
                store: store, destination: destination, includeAudio: includeAudio, adapter: adapter
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
            let description = includeAudio ? "History and recording audio" : "History text"
            let status: String
            switch outcome {
            case .saved:
                status = "Saved \(description) backup as \(destination.lastPathComponent)."
            case let .savedWithWarning(warning):
                status = "Saved \(description) backup as \(destination.lastPathComponent). \(warning)"
            case .cancelled:
                status = "History backup cancelled. No destination was published; existing files were kept."
            case let .failed(message):
                status = "Could not save History backup: \(message)"
            }
            showSelectedHistory(status: status, state: 0)
        }
    }
}
