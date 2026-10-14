import Foundation

/// Plans preservation-only additions, never effective settings or transactional replacement.
public enum DesktopNativeRetentionMergePolicy {
    public struct Conflict: Sendable, Equatable {
        public let existing: DataMigrationRecord
        public let incoming: DataMigrationRecord
        public var identity: String { existing.id }
    }

    public struct Plan: Sendable {
        public let proposed: DesktopNativeConfigurationArchive
        public let additions: [DataMigrationRecord]
        public let unchangedIDs: Set<String>
        public let conflicts: [Conflict]
        public var hasConflicts: Bool { !conflicts.isEmpty }
    }

    public static func plan(
        existing: [DataMigrationRecord], incoming: [DataMigrationRecord],
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Plan {
        let retained = try DesktopNativeConfigurationArchiveCodec.inspect(
            existing, checkCancellation: checkCancellation
        )
        let selected = try DesktopNativeConfigurationArchiveCodec.inspect(
            incoming, checkCancellation: checkCancellation
        )
        var merged = Dictionary(uniqueKeysWithValues: retained.records.map { ($0.id, $0) })
        var additions: [DataMigrationRecord] = []
        var unchanged = Set<String>()
        var conflicts: [Conflict] = []
        for record in selected.records {
            try checkCancellation()
            if let prior = merged[record.id] {
                if prior == record { unchanged.insert(record.id) } else {
                    conflicts.append(.init(existing: prior, incoming: record))
                }
            } else {
                merged[record.id] = record
                additions.append(record)
            }
        }
        let proposed = try DesktopNativeConfigurationArchiveCodec.inspect(
            Array(merged.values), checkCancellation: checkCancellation
        )
        return .init(proposed: proposed, additions: additions, unchangedIDs: unchanged, conflicts: conflicts)
    }
}
