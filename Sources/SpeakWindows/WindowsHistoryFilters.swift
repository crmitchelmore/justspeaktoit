import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost

func windowsHistoryManagementEvent(
    _ event: Int32, value: String, index: Int, holder: WindowsEventContext
) -> Bool {
    switch event {
    case 90: holder.submitHistoryPlayback(.filter(value))
    case 91:
        let controller = holder.controller
        holder.enqueueSettings { await controller.beginHistoryDeletion(value, deleteAudio: index == 1) }
    case 93: Task { await holder.controller.revealRecordingsDirectory() }
    case 94: holder.enqueueSettings { await holder.controller.beginAudioCleanupConfirmation() }
    case 95: holder.enqueueSettings { await holder.controller.answerAudioCleanup(value, delete: index == 1) }
    case 96:
        holder.enqueueSettings {
            await holder.controller.beginMigrationExport(URL(fileURLWithPath: value), nativeFlags: index)
        }
    case 97:
        holder.enqueueSettings { await holder.controller.beginMigrationInspection(URL(fileURLWithPath: value)) }
    case 98: holder.enqueueSettings { await holder.controller.beginMigrationRestore(URL(fileURLWithPath: value)) }
    case 99: holder.enqueueSettings { await holder.controller.answerMigrationRestore(value, choice: index) }
    default: return false
    }
    return true
}

extension WindowsHostPlatform {
    package static func historyFilters(models: [String], selection: DesktopHistoryFilter) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { $0.deallocate() } }
        func owned(_ value: String) -> UnsafePointer<CChar> {
            let bytes = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            strings.append(pointer)
            return UnsafePointer(pointer)
        }
        let rows = models.map { model in
            JSTIHistoryFilterModel(
                id: owned(model), name: owned(DesktopHistorySearch.modelDisplayName(for: model)),
                selected: selection.models.contains(model) ? 1 : 0
            )
        }
        let result = rows.withUnsafeBufferPointer {
            jsti_window_set_history_filters(
                $0.baseAddress, $0.count, selection.errorsOnly ? 1 : 0, selection.fromDay, selection.throughDay
            )
        }
        if result != 0 { update("Could not update History filter controls.") }
    }
}
