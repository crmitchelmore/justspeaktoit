import Foundation
import SpeakCore

enum MigrationPlanner {
    static func conflicts(current: MigrationSnapshot, incoming: MigrationSnapshot,
                          modes: [MigrationCategory: MigrationMode]) -> [MigrationConflict] {
        DataMigrationPlanner.conflicts(current: current, incoming: incoming, modes: modes).map {
            MigrationConflict(category: $0.category, existing: $0.existing, imported: $0.imported)
        }
    }

    static func plan(current: MigrationSnapshot, incoming: MigrationSnapshot,
                     modes: [MigrationCategory: MigrationMode],
                     useImported: Set<String>) throws -> MigrationSnapshot {
        try DataMigrationPlanner.plan(
            current: current, incoming: incoming, modes: modes, useImported: useImported,
            digest: MigrationCoding.digest
        )
    }
}

extension HistoryItem {
    func migrationValue(audioOnly: Bool = false, audioURL: URL? = nil,
                        id: String? = nil) throws -> AnyCodable {
        try DataMigrationHistoryValue.value(
            MigrationCoding.value(self), audioOnly: audioOnly, audioURL: audioURL, id: id
        )
    }
}
