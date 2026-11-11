import Foundation
import SpeakCore

public enum DesktopMigrationPlanner {
    public static func plan(
        current: DataMigrationSnapshot, incoming: DataMigrationSnapshot,
        modes: [DataMigrationCategory: DataMigrationMode], useImported: Set<String>,
        digests: LocalModelDigestProvider
    ) throws -> DataMigrationSnapshot {
        try DataMigrationPlanner.plan(
            current: current, incoming: incoming, modes: modes, useImported: useImported,
            digest: { try digests.sha256(of: $0) }
        )
    }
}
