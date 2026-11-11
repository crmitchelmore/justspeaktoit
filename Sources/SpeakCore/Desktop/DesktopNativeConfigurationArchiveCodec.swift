import Foundation

/// Isolated closed native-source codec; existing migration acceptance remains unchanged.
public enum DesktopNativeConfigurationArchiveCodec {
    public static let recordKind = "nativeConfiguration"
    public static let schemaVersion = 1
    public static let maximumEncodedBytes = DataMigrationArchivePolicy.maximumJSONBytes
    public static let maximumRecords = DesktopNativeConfigurationField.allCases.count
        * DesktopNativeConfigurationCapture.Platform.allCases.count

    public static func identity(
        platform: DesktopNativeConfigurationCapture.Platform, field: DesktopNativeConfigurationField
    ) -> String {
        "native/\(platform.rawValue)/\(field.rawValue)"
    }

    public static func project(
        _ capture: DesktopNativeConfigurationCapture,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeConfigurationArchive {
        try checkCancellation()
        guard capture.entries.count <= DesktopNativeConfigurationField.allCases.count else { throw invalid() }
        let records = try capture.entries.map { entry in
            try checkCancellation()
            guard entry.platform == capture.platform, entry.provenance == entry.field.provenance else {
                throw invalid()
            }
            var value: [String: AnyCodable.JSONValue] = [
                "schemaVersion": .int(schemaVersion), "sourcePlatform": .string(entry.platform.rawValue),
                "sourcePath": .string(entry.sourcePath), "provenance": .string(entry.provenance.rawValue),
                "isPresent": .bool(entry.isPresent)
            ]
            if let raw = entry.value { value["value"] = raw.storage }
            return DataMigrationRecord(
                id: identity(platform: entry.platform, field: entry.field),
                kind: recordKind, value: AnyCodable(.object(value))
            )
        }
        let projection = try inspect(records, checkCancellation: checkCancellation)
        return .init(records: projection.records, entries: projection.entries, coverage: projection.coverage,
                     unresolvedPaths: capture.unresolvedPaths)
    }

    public static func inspect(
        _ records: [DataMigrationRecord], category: DataMigrationCategory = .settings,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeConfigurationArchive {
        try checkCancellation()
        guard category == .settings, records.count <= maximumRecords else { throw invalid() }
        var seen = Set<String>()
        var bytes: UInt64 = 4
        var entries: [DesktopNativeConfigurationCapture.Entry] = []
        for record in records {
            try checkCancellation()
            let entry = try decode(record, checkCancellation: checkCancellation)
            guard seen.insert(record.id).inserted else { throw invalid() }
            entries.append(entry)
            let encoded = try DataMigrationCoding.encoder.encode(record)
            try checkCancellation()
            var lines: UInt64 = 1
            for (index, byte) in encoded.enumerated() {
                if index % 4096 == 0 { try checkCancellation() }
                if byte == 10 { lines += 1 }
            }
            bytes += UInt64(encoded.count) + 2 * lines + (entries.count == 1 ? 0 : 2)
            guard bytes <= maximumEncodedBytes else { throw invalid() }
        }
        let ordered = records.sorted { $0.id < $1.id }
        let orderedEntries = entries.sorted {
            identity(platform: $0.platform, field: $0.field) < identity(platform: $1.platform, field: $1.field)
        }
        return .init(records: ordered, entries: orderedEntries,
                     coverage: .init(keys: seen), unresolvedPaths: [])
    }

    public static func encode(
        _ projection: DesktopNativeConfigurationArchive,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Data {
        let validated = try inspect(projection.records, checkCancellation: checkCancellation)
        let data = try DataMigrationCoding.encoder.encode(validated.records)
        try checkCancellation()
        guard UInt64(data.count) <= maximumEncodedBytes else { throw invalid() }
        return data
    }

    public static func decode(
        _ data: Data, checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeConfigurationArchive {
        try NativeConfigurationJSONScan.validate(data, checkCancellation: checkCancellation)
        let value = try DataMigrationCoding.decoder.decode(AnyCodable.self, from: data)
        try checkCancellation()
        guard case .array(let objects) = value.storage, objects.count <= maximumRecords else { throw invalid() }
        let records = try objects.map { object in
            try checkCancellation()
            guard case .object(let fields) = object, Set(fields.keys) == ["id", "kind", "value"],
                  case .string(let id) = fields["id"], case .string(let kind) = fields["kind"],
                  let payload = fields["value"] else { throw invalid() }
            return DataMigrationRecord(id: id, kind: kind, value: AnyCodable(payload))
        }
        return try inspect(records, checkCancellation: checkCancellation)
    }

    public static func decode(
        _ record: DataMigrationRecord,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeConfigurationCapture.Entry {
        try checkCancellation()
        guard record.kind == recordKind, record.date == nil, record.file == nil,
              record.digest == nil, record.revision == nil,
              case .object(let object) = record.value.storage, object.count <= 6 else { throw invalid() }
        let header = try decodeHeader(object)
        let expected: Set<String> = ["schemaVersion", "sourcePlatform", "sourcePath", "provenance", "isPresent"]
        guard Set(object.keys) == (header.isPresent ? expected.union(["value"]) : expected),
              record.id == identity(platform: header.platform, field: header.field) else { throw invalid() }
        let value = object["value"].map(AnyCodable.init)
        if let value {
            try validateSize(value, checkCancellation: checkCancellation)
            try header.field.validate(value, platform: header.platform)
        }
        try checkCancellation()
        return .init(field: header.field, platform: header.platform, provenance: header.field.provenance, value: value)
    }

    private static func decodeHeader(_ object: [String: AnyCodable.JSONValue]) throws -> NativeConfigurationHeader {
        guard case .int(let version) = object["schemaVersion"], version == schemaVersion,
              case .string(let platformName) = object["sourcePlatform"],
              let platform = DesktopNativeConfigurationCapture.Platform(rawValue: platformName),
              case .string(let path) = object["sourcePath"],
              let field = DesktopNativeConfigurationField(rawValue: path),
              case .string(let provenance) = object["provenance"], provenance == field.provenance.rawValue,
              case .bool(let isPresent) = object["isPresent"] else { throw invalid() }
        return .init(platform: platform, field: field, isPresent: isPresent)
    }

    private static func validateSize(_ value: AnyCodable, checkCancellation: () throws -> Void) throws {
        var remaining = maximumEncodedBytes
        var stack = [(value.storage, 0)]
        var nodes = 0
        while let (item, depth) = stack.popLast() {
            try checkCancellation()
            nodes += 1
            guard depth <= 8, nodes <= 1024 else { throw invalid() }
            switch item {
            case .string(let text):
                try consumeString(text, remaining: &remaining, checkCancellation: checkCancellation)
            case .object(let object):
                guard object.count <= 32 else { throw invalid() }
                stack += object.values.map { ($0, depth + 1) }
                stack += object.keys.map { (.string($0), depth + 1) }
            case .array(let array):
                guard array.count <= 32 else { throw invalid() }
                stack += array.map { ($0, depth + 1) }
            case .double(let number):
                guard number.isFinite else { throw invalid() }
            default:
                break
            }
        }
    }

    private static func consumeString(
        _ text: String, remaining: inout UInt64, checkCancellation: () throws -> Void
    ) throws {
        for (index, byte) in text.utf8.enumerated() {
            if index % 4096 == 0 { try checkCancellation() }
            let width: UInt64
            switch byte {
            case 34, 92, 8, 9, 10, 12, 13: width = 2
            case 0..<32: width = 6
            default: width = 1
            }
            guard remaining >= width else { throw invalid() }
            remaining -= width
        }
    }

    private static func invalid() -> DataMigrationError {
        .invalid("Malformed, unclassified or oversized native configuration archive record.")
    }
}

private struct NativeConfigurationHeader {
    let platform: DesktopNativeConfigurationCapture.Platform
    let field: DesktopNativeConfigurationField
    let isPresent: Bool
}
