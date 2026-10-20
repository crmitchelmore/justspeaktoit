import Foundation

public enum DataMigrationCollectionRecords {
    public static func records(
        data: Data, kind: String, digest: (Data) throws -> String, checkCancellation: () throws -> Void = {}
    ) throws -> [DataMigrationRecord] {
        try checkCancellation()
        guard UInt64(data.count) <= DataMigrationArchivePolicy.maximumJSONBytes else {
            throw DataMigrationError.invalid("The collection exceeds the archive JSON limit.")
        }
        let values = try JSONDecoder().decode([AnyCodable].self, from: data)
        try checkCancellation()
        var result: [DataMigrationRecord] = []
        var encodedBytes: UInt64 = 0
        for value in values {
            try checkCancellation()
            let object: [String: AnyCodable.JSONValue]
            if case let .object(fields) = value.storage {
                object = fields
            } else {
                object = [:]
            }
            let id: String
            if case let .string(rawID)? = object["id"] {
                id = rawID
            } else {
                id = try digest(DataMigrationCoding.encoder.encode(value))
            }
            let date: Date?
            switch object["timestamp"] {
            case let .string(timestamp)?:
                date = ISO8601DateFormatter().date(from: timestamp)
            case let .int(timestamp)?:
                date = Date(timeIntervalSinceReferenceDate: Double(timestamp))
            case let .double(timestamp)?:
                date = Date(timeIntervalSinceReferenceDate: timestamp)
            default:
                date = nil
            }
            let record = DataMigrationRecord(id: id, kind: kind, value: value, date: date)
            encodedBytes += UInt64(try DataMigrationCoding.encoder.encode(record).count)
            guard encodedBytes <= DataMigrationArchivePolicy.maximumJSONBytes else {
                throw DataMigrationError.invalid("The collection records exceed the archive JSON limit.")
            }
            result.append(record)
        }
        try checkCancellation()
        guard UInt64(try DataMigrationCoding.encoder.encode(result).count)
            <= DataMigrationArchivePolicy.maximumJSONBytes else {
            throw DataMigrationError.invalid("The collection records exceed the archive JSON limit.")
        }
        try checkCancellation()
        return result
    }
}
