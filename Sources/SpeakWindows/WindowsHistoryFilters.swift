import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings

/// History filters, deletion, recordings folder, cleanup and migration
/// events, in settings order. False for others.
func windowsHistoryManagementEvent(
    _ event: DesktopNativeWindowEvent, value: String, index: Int, holder: WindowsEventContext
) -> Bool {
    let controller = holder.controller
    switch event {
    case .historyFilters: holder.submitHistoryPlayback(.filter(value))
    case .historyDelete:
        holder.enqueueSettings { await controller.beginHistoryDeletion(value, deleteAudio: index == 1) }
    case .recordingsFolder: Task { await controller.revealRecordingsDirectory() }
    case .audioCleanup: holder.enqueueSettings { await controller.beginAudioCleanupConfirmation() }
    case .audioCleanupResponse:
        holder.enqueueSettings { await controller.answerAudioCleanup(value, delete: index == 1) }
    case .migrationExport:
        let url = URL(fileURLWithPath: value)
        holder.enqueueSettings { await controller.beginMigrationExport(url, nativeFlags: index) }
    case .migrationInspect:
        holder.enqueueSettings { await controller.beginMigrationInspection(URL(fileURLWithPath: value)) }
    case .migrationRestore:
        holder.enqueueSettings { await controller.beginMigrationRestore(URL(fileURLWithPath: value)) }
    case .migrationRestoreResponse:
        holder.enqueueSettings { await controller.answerMigrationRestore(value, choice: index) }
    default: return false
    }
    return true
}

extension WindowsHostPlatform {
    package static func historyFilters(models: [String], selection: DesktopHistoryFilter) {
        if !DesktopNativeBindings.historyFilters(models: models, selection: selection) {
            update("Could not update History filter controls.")
        }
    }
}
