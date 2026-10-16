import Foundation
import SpeakDesktop

package struct DesktopHostMigrationInspector: Sendable {
    let reader: DesktopMigrationInspection.Reader
    let present: @Sendable (DesktopMigrationInspection.Report) throws -> Void

    package init(
        reader: DesktopMigrationInspection.Reader,
        present: @escaping @Sendable (DesktopMigrationInspection.Report) throws -> Void
    ) {
        self.reader = reader
        self.present = present
    }
}

extension DesktopHostPlatform {
    package static var migrationInspector: DesktopHostMigrationInspector? { nil }
}

extension DesktopHostController {
    /// Admission only; the reader and staging cleanup never occupy the settings queue.
    package func beginMigrationInspection(_ source: URL, using inspector: DesktopHostMigrationInspector? = nil) {
        guard !closed else { return }
        guard canUseHistory, migrationInspectionTask == nil, audioCleanupConfirmation == nil else {
            let state: Int32
            if busy { state = 2 } else if recording != nil { state = 1 } else { state = 0 }
            update("Backup inspection is unavailable while another operation or confirmation is running.", state: state)
            return
        }
        guard let inspector = inspector ?? Platform.migrationInspector else {
            update("Backup inspection is unavailable on this host.")
            return
        }
        busy = true
        cancellationRequested = false
        activeOperations += 1
        update("Inspecting backup... No application data will be changed.", state: 2)
        let worker = Task.detached {
            await DesktopMigrationInspection.inspect(source, reader: inspector.reader)
        }
        migrationInspectionWorker = worker
        migrationInspectionTask = Task {
            let outcome = await worker.value
            defer {
                migrationInspectionWorker = nil
                migrationInspectionTask = nil
                busy = false
                finishOperation()
            }
            guard !closed else { return }
            switch outcome {
            case let .inspected(report):
                do {
                    try inspector.present(report)
                    showSelectedHistory(status: "Backup inspected. No application data was changed.", state: 0)
                } catch {
                    showSelectedHistory(
                        status: "Could not show backup inspection: \(error.localizedDescription)", state: 0
                    )
                }
            case .cancelled:
                showSelectedHistory(status: "Backup inspection cancelled. No application data was changed.", state: 0)
            case let .failed(message):
                showSelectedHistory(status: "Could not inspect backup: \(message)", state: 0)
            }
        }
    }
}
