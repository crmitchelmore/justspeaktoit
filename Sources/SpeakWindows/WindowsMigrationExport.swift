import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

extension WindowsHostPlatform {
    package static var migrationInspector: DesktopHostMigrationInspector? {
        .init(reader: .init { try WindowsMigrationArchive.read($0) }, digests: WindowsSHA256Hasher.provider,
              present: { report in
            try WindowsNative.checked { error, capacity in
                jsti_window_show_migration_report(report.text, error, capacity)
            }
        })
    }

    package static var migrationRestorer: DesktopHostMigrationRestorer? {
        .init(reader: .init { try WindowsMigrationArchive.read($0) }, digests: WindowsSHA256Hasher.provider,
              confirm: { token, text, offersReplace in
            try WindowsNative.checked { error, capacity in
                jsti_window_confirm_migration_restore(token, text, offersReplace ? 1 : 0, error, capacity)
            }
        })
    }

    package static var migrationArchive: DesktopMigrationBackup.Adapter? {
        .init(
            digests: WindowsSHA256Hasher.provider,
            archive: { try WindowsMigrationArchive.export($0) },
            publish: { try WindowsMigrationArchive.publish($0, to: $1) }
        )
    }
}
