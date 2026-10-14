import Foundation
import SpeakCore
import SpeakDesktop

public enum LinuxMigrationArchive {
    public static let storage = DesktopMigrationArchive.Storage(
        createDirectory: { try LinuxFiles.createPrivateDirectory($0) },
        createFile: { try LinuxFiles.createPrivateFile($0) }
    )

    public static func read(
        _ source: URL, digests: LocalModelDigestProvider = LinuxSHA256Hasher.provider,
        stagingRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> DataMigrationSnapshot {
        try DesktopMigrationArchive.read(source, digests: digests, stagingRoot: stagingRoot, storage: storage)
    }

    public static func export(
        _ snapshot: DataMigrationSnapshot, digests: LocalModelDigestProvider = LinuxSHA256Hasher.provider,
        stagingRoot: URL = FileManager.default.temporaryDirectory, includeCredentials: Bool = false
    ) throws -> URL {
        try DesktopMigrationArchive.export(
            snapshot, digests: digests, stagingRoot: stagingRoot,
            includeCredentials: includeCredentials, storage: storage
        )
    }
}
