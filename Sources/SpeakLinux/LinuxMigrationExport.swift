import SpeakDesktop
import SpeakLinuxPlatform

extension LinuxHostPlatform {
    package static var migrationArchive: DesktopMigrationBackup.Adapter? {
        .init(
            digests: LinuxSHA256Hasher.provider,
            archive: { try LinuxMigrationArchive.export($0) },
            publish: { try LinuxMigrationArchive.publish($0, to: $1) }
        )
    }
}
