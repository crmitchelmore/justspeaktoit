import Foundation

public enum DataMigrationRecordValidation {
    public static func validate(
        _ incoming: DataMigrationSnapshot,
        recordValidator: (DataMigrationRecord, DataMigrationCategory) throws -> Void
    ) -> DataMigrationSnapshot {
        filtered(incoming) { record, category, notices in
            do {
                try validate(record, category: category, incoming: incoming, using: recordValidator)
                return true
            } catch {
                notices.append(invalidNotice(record, category: category))
                return false
            }
        }
    }

    /// Cancellation aborts the pass instead of producing invalid-item notices or partial applicable data.
    public static func validate(
        _ incoming: DataMigrationSnapshot,
        checkCancellation: () throws -> Void,
        recordValidator: (DataMigrationRecord, DataMigrationCategory) throws -> Void
    ) throws -> DataMigrationSnapshot {
        try checkCancellation()
        let result = try filtered(incoming) { record, category, notices in
            try checkCancellation()
            let accepted: Bool
            do {
                try validate(record, category: category, incoming: incoming, using: recordValidator)
                accepted = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                notices.append(invalidNotice(record, category: category))
                accepted = false
            }
            try checkCancellation()
            return accepted
        }
        try checkCancellation()
        return result
    }

    private static func filtered(
        _ incoming: DataMigrationSnapshot,
        accept: (DataMigrationRecord, DataMigrationCategory, inout [String]) throws -> Bool
    ) rethrows -> DataMigrationSnapshot {
        var validated = incoming
        for category in incoming.manifest.categories {
            guard let records = incoming.records[category] else { continue }
            var accepted: [DataMigrationRecord] = []
            for record in records where try accept(record, category, &validated.notices) {
                accepted.append(record)
            }
            validated.records[category] = accepted
        }
        return validated
    }

    private static func validate(
        _ record: DataMigrationRecord, category: DataMigrationCategory, incoming: DataMigrationSnapshot,
        using recordValidator: (DataMigrationRecord, DataMigrationCategory) throws -> Void
    ) throws {
        try recordValidator(record, category)
        if category == .history || category == .recordings {
            let scope = incoming.manifest.scopes[category.rawValue] ?? DataMigrationScope()
            guard scope.contains(id: record.id, date: record.date) else {
                throw DataMigrationError.invalid("Item is outside the exported selection")
            }
        }
    }

    private static func invalidNotice(_ record: DataMigrationRecord, category: DataMigrationCategory) -> String {
        "\(category.title), \(record.id): skipped invalid or unsupported item."
    }
}
