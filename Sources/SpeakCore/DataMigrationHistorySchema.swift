import Foundation

public enum DataMigrationHistorySchema {
    public static func validate(
        _ record: DataMigrationRecord, category: DataMigrationCategory
    ) throws -> ApplicationHistoryItem {
        guard (record.kind == "history" && category == .history)
            || (record.kind == "audio" && category == .recordings),
            UUID(uuidString: record.id) != nil else {
            throw DataMigrationError.invalid("Invalid history identifier")
        }
        let item = try DataMigrationCoding.decode(ApplicationHistoryItem.self, record.value)
        guard item.id.uuidString.lowercased() == record.id.lowercased(), item.recordingDuration >= 0,
              record.date.map({ abs(item.createdAt.timeIntervalSince($0)) < 1 }) == true else {
            throw DataMigrationError.invalid("Invalid history item")
        }
        return item
    }
}
