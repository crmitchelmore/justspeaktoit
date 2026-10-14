import CLinuxSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform

extension LinuxHostPlatform {
    package static var migrationInspector: DesktopHostMigrationInspector? {
        .init(reader: .init { try LinuxMigrationArchive.read($0) }, digests: LinuxSHA256Hasher.provider, present: {
            guard jsti_window_show_migration_report($0.text) == 0 else {
                throw DesktopHostError(message: "The native backup inspection report is unavailable.")
            }
        })
    }

    package static var migrationArchive: DesktopMigrationBackup.Adapter? {
        .init(
            digests: LinuxSHA256Hasher.provider,
            archive: { try LinuxMigrationArchive.export($0) },
            publish: { try LinuxMigrationArchive.publish($0, to: $1) }
        )
    }
}
