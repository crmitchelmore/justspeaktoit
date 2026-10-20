import Foundation
import CLinuxSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform

extension LinuxHostPlatform {
    package static var migrationRestorer: DesktopHostMigrationRestorer? {
        .init(reader: .init { try LinuxMigrationArchive.read($0) }, digests: LinuxSHA256Hasher.provider,
              confirm: { token, text, offersReplace in
            guard jsti_window_confirm_migration_restore(token, text, offersReplace ? 1 : 0) == 0 else {
                throw DesktopHostError(message: "The native backup restore preview is unavailable.")
            }
        })
    }
}

/// Queue admission only. Archive reading, apply and rollback keep their shared
/// owned workers, so Cancel and window shutdown never wait on the settings queue.
func linuxMigrationEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    let controller = holder.controller
    switch event {
    case Int(JSTI_EVENT_MIGRATION_INSPECT):
        holder.enqueueSettings { await controller.beginMigrationInspection(URL(fileURLWithPath: value)) }
    case Int(JSTI_EVENT_MIGRATION_EXPORT):
        holder.enqueueSettings {
            await controller.beginMigrationExport(URL(fileURLWithPath: value), nativeFlags: slot)
        }
    case Int(JSTI_EVENT_MIGRATION_RESTORE):
        holder.enqueueSettings { await controller.beginMigrationRestore(URL(fileURLWithPath: value)) }
    case Int(JSTI_EVENT_MIGRATION_RESTORE_RESPONSE):
        holder.enqueueSettings { await controller.answerMigrationRestore(value, choice: slot) }
    default: return false
    }
    return true
}
