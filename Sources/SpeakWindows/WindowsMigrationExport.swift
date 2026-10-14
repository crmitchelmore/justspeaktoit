import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

extension WindowsHostPlatform {
    package static var migrationInspector: DesktopHostMigrationInspector? {
        .init(reader: .init { try WindowsMigrationArchive.read($0) }, present: { report in
            try WindowsNative.checked { error, capacity in
                jsti_window_show_migration_report(report.text, error, capacity)
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
