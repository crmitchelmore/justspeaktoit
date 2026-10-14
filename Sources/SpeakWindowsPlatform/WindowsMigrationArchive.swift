import CWindowsSupport
import Foundation
import SpeakCore
import SpeakDesktop

public enum WindowsMigrationArchive {
    public static let storage = DesktopMigrationArchive.Storage(
        createDirectory: { url in try checked { jsti_private_directory_create(url.path, $0, $1) } },
        createFile: { url in try checked { jsti_private_file_create(url.path, $0, $1) } }
    )

    public static func read(
        _ source: URL, digests: LocalModelDigestProvider = WindowsSHA256Hasher.provider,
        stagingRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> DataMigrationSnapshot {
        try DesktopMigrationArchive.read(source, digests: digests, stagingRoot: stagingRoot, storage: storage)
    }

    public static func export(
        _ snapshot: DataMigrationSnapshot, digests: LocalModelDigestProvider = WindowsSHA256Hasher.provider,
        stagingRoot: URL = FileManager.default.temporaryDirectory, includeCredentials: Bool = false
    ) throws -> URL {
        try DesktopMigrationArchive.export(
            snapshot, digests: digests, stagingRoot: stagingRoot,
            includeCredentials: includeCredentials, storage: storage
        )
    }

    private static func checked(_ action: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var error = [CChar](repeating: 0, count: 1_024)
        guard action(&error, error.count) == 0 else {
            throw DataMigrationError.invalid(String(cString: error))
        }
    }
}
