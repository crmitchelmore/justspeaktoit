import SpeakDesktop
import SpeakWindowsPlatform

extension WindowsHostPlatform {
    package static var migrationArchive: DesktopMigrationBackup.Adapter? {
        .init(
            digests: WindowsSHA256Hasher.provider,
            archive: { try WindowsMigrationArchive.export($0) },
            publish: { try WindowsMigrationArchive.publish($0, to: $1) }
        )
    }
}
