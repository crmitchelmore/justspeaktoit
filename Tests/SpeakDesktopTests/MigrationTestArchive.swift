import Foundation
import SpeakCore
import SpeakDesktop
#if os(Windows)
import SpeakWindowsPlatform
#endif

enum MigrationTestArchive {
    private static var storage: DesktopMigrationArchive.Storage? {
        #if os(Windows)
        WindowsMigrationArchive.storage
        #else
        nil
        #endif
    }

    static func read(
        _ source: URL, digests: LocalModelDigestProvider, stagingRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> DataMigrationSnapshot {
        try DesktopMigrationArchive.read(source, digests: digests, stagingRoot: stagingRoot, storage: storage)
    }

    static func export(
        _ snapshot: DataMigrationSnapshot, digests: LocalModelDigestProvider,
        stagingRoot: URL = FileManager.default.temporaryDirectory, includeCredentials: Bool = false
    ) throws -> URL {
        try DesktopMigrationArchive.export(
            snapshot, digests: digests, stagingRoot: stagingRoot,
            includeCredentials: includeCredentials, storage: storage
        )
    }
}
