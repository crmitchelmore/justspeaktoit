import CLinuxSupport
import Foundation
import SpeakCore
import SpeakDesktop

public enum LinuxMigrationArchive {
    public static func publish(_ source: URL, to destination: URL) throws {
        try DesktopFilePublication.copy(source: source, destination: destination, using: .init { source, destination in
            var error = [CChar](repeating: 0, count: 1_024)
            let result = source.path.withCString { source in
                destination.path.withCString { destination in
                    jsti_private_file_publish(
                        source, destination, { _ in Task.isCancelled ? 1 : 0 }, nil, &error, error.count
                    )
                }
            }
            if result == 2 { throw CancellationError() }
            if result == 3 {
                throw DesktopFilePublication.CopyCompletionFailure(
                    destination: destination, detail: String(cString: error)
                )
            }
            guard result == 0 else { throw DataMigrationError.invalid(String(cString: error)) }
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
