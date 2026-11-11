import Foundation
import SpeakCore

extension DesktopMigrationInspection {
    static func mergePreview(
        _ incoming: DataMigrationSnapshot, comparison: Comparison?
    ) async throws -> [MergeCategory] {
        try Task.checkCancellation()
        guard let comparison else { return [] }
        let declared = [DataMigrationCategory.history, .recordings].filter(incoming.manifest.categories.contains)
        let readable = Set(declared.filter { incoming.records[$0] != nil })
        guard !readable.isEmpty else {
            return declared.map { .init(category: $0, changes: nil) }
        }
        let current = try await comparison.current(readable)
        try Task.checkCancellation()
        let validated = try DataMigrationRecordValidation.validate(
            current, checkCancellation: { try Task.checkCancellation() },
            recordValidator: { record, category in
                if readable.contains(category) {
                    _ = try DesktopMigrationHistory.record(record, category: category)
                }
            }
        )
        for category in readable {
            guard current.manifest.categories.contains(category),
                  let records = current.records[category],
                  validated.records[category] == records,
                  !current.notices.contains(where: {
                      $0.hasPrefix(category.title + ":") || $0.hasPrefix(category.title + ",")
                  }) else {
                throw DataMigrationError.invalid("Current \(category.title) could not be validated for merge preview.")
            }
            try requireUnique(records, category: category)
            try requireUnique(incoming.records[category] ?? [], category: category)
        }
        let modes = Dictionary(uniqueKeysWithValues: readable.map { ($0, DataMigrationMode.merge) })
        let planned = try DesktopMigrationPlanner.plan(
            current: current, incoming: incoming, modes: modes, useImported: [], digests: comparison.digests
        )
        let result = try declared.map { category -> MergeCategory in
            try Task.checkCancellation()
            guard readable.contains(category) else { return .init(category: category, changes: nil) }
            return .init(category: category, changes: try changes(
                existing: current.records[category] ?? [], retained: planned.records[category] ?? []
            ))
        }
        try Task.checkCancellation()
        return result
    }

    private static func changes(
        existing: [DataMigrationRecord], retained: [DataMigrationRecord]
    ) throws -> MergeChanges {
        let originals = Dictionary(uniqueKeysWithValues: existing.map { ($0.identity, $0) })
        var added = 0
        var updated = 0
        for record in retained {
            try Task.checkCancellation()
            if let original = originals[record.identity] {
                if original != record { updated += 1 }
            } else {
                added += 1
            }
        }
        return .init(existing: existing.count, added: added, updated: updated, retained: retained.count)
    }

    private static func requireUnique(_ records: [DataMigrationRecord], category: DataMigrationCategory) throws {
        var identities = Set<String>()
        for record in records {
            try Task.checkCancellation()
            guard identities.insert(record.identity).inserted else {
                throw DataMigrationError.invalid("\(category.title): duplicate identities prevent merge preview.")
            }
        }
    }
}
