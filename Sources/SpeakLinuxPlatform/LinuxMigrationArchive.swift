import CLinuxSupport
import Foundation
import SpeakCore
import SpeakDesktop

public enum LinuxMigrationArchive {
    public static func publish(_ source: URL, to destination: URL) throws {
        try DesktopFilePublication.copy(source: source, destination: destination, using: .native {
            jsti_private_file_publish($0, $1, { _ in Task.isCancelled ? 1 : 0 }, nil, $2, $3)
        })
    }

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
