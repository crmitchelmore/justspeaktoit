import Foundation
import SpeakCore

extension DesktopDictationProfileStore {
    public func migrationSnapshot(
        digests: LocalModelDigestProvider,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DataMigrationSnapshot {
        try DesktopProfileDocumentAccess.withMutation {
            try migrationSnapshotUnlocked(digests: digests, checkCancellation: checkCancellation)
        }
    }

    private func migrationSnapshotUnlocked(
        digests: LocalModelDigestProvider, checkCancellation: () throws -> Void
    ) throws -> DataMigrationSnapshot {
        let source = try DesktopOwnedAppDataFileReader.readStrict(
            Self.filename, appDirectory: fileURL.deletingLastPathComponent(),
            maximumBytes: DataMigrationArchivePolicy.maximumJSONBytes, checkCancellation: checkCancellation
        )
        let records = try source.data.map {
            try DataMigrationProfileCatalog.records(
                data: $0, digest: digests.sha256(of:), checkCancellation: checkCancellation
            )
        } ?? []
        try DesktopOwnedAppDataFileReader.revalidateStrict(
            source.receipt, checkCancellation: checkCancellation
        )
        return DataMigrationSnapshot(
            manifest: .init(
                categories: [.profiles], scopes: [
                    DataMigrationCategory.profiles.rawValue: .init(
                        start: nil, end: nil, selectedIDs: nil, selectedKinds: [DataMigrationProfileCatalog.kind]
                    )
                ]
            ),
            records: [.profiles: records]
        )
    }
}
