import Foundation

public enum DataMigrationRecordValidation {
    public static func validate(
        _ incoming: DataMigrationSnapshot,
        recordValidator: (DataMigrationRecord, DataMigrationCategory) throws -> Void
    ) -> DataMigrationSnapshot {
        var validated = incoming
        for category in incoming.manifest.categories {
            guard let records = incoming.records[category] else { continue }
            validated.records[category] = records.filter { record in
                do {
                    try recordValidator(record, category)
                    if category == .history || category == .recordings {
                        let scope = incoming.manifest.scopes[category.rawValue] ?? DataMigrationScope()
                        guard scope.contains(id: record.id, date: record.date) else {
                            throw DataMigrationError.invalid("Item is outside the exported selection")
                        }
                    }
                    return true
                } catch {
                    validated.notices.append("\(category.title), \(record.id): skipped invalid or unsupported item.")
                    return false
                }
            }
        }
        return validated
    }
}
