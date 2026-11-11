import Foundation

/// Opt-in local preservation only. Future unencrypted export must warn that sensitive text/secrets may be included.
public enum DesktopNativeSourceDocumentCodec {
    public static let recordKind = "nativeSourceDocument"
    public static let maximumBytes = DataMigrationArchivePolicy.maximumJSONBytes

    private static let header: Set<String> = [
        "schemaVersion", "sourcePlatform", "sourceRoot", "sourcePath", "provenance", "isPresent"
    ]
    private static let limits = JSONMemberPreflight.Limits(
        maximumBytes: maximumBytes, maximumDepth: 3, maximumTokens: 128,
        maximumRootRecords: DesktopNativeSourceDocument.Source.allCases.count
            * DesktopNativeSourceDocument.Platform.allCases.count,
        maximumObjectKeys: 8, maximumEncodedKeySpan: 512, cancellationStride: 4096
    )

    public static func capture(
        platform: DesktopNativeSourceDocument.Platform, source: DesktopNativeSourceDocument.Source,
        rawBytes: Data?, allowSensitiveContent: Bool = false,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeSourceDocument.Evidence {
        try requireOptIn(allowSensitiveContent)
        try checkCancellation()
        guard UInt64(rawBytes?.count ?? 0) <= maximumBytes else { throw invalid() }
        let evidence = DesktopNativeSourceDocument.Evidence(platform: platform, source: source, rawBytes: rawBytes)
        _ = try project([evidence], allowSensitiveContent: true, checkCancellation: checkCancellation)
        return evidence
    }

    public static func project(
        _ evidence: [DesktopNativeSourceDocument.Evidence], allowSensitiveContent: Bool = false,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeSourceDocument.Projection {
        try requireOptIn(allowSensitiveContent)
        try checkCancellation()
        guard evidence.count <= limits.maximumRootRecords else { throw invalid() }
        var ids = Set<String>()
        var records: [DataMigrationRecord] = []
        let ordered = evidence.sorted { $0.identity < $1.identity }
        let headers = ordered.map {
            record(.init(platform: $0.platform, source: $0.source, rawBytes: $0.rawBytes.map { _ in Data() }))
        }
        try admitSizes(ordered.map { UInt64($0.rawBytes?.count ?? 0) },
                       encodedHeaderBytes: UInt64(DataMigrationCoding.encoder.encode(headers).count))
        var bytes: UInt64 = 0
        for item in ordered {
            try checkCancellation()
            guard ids.insert(item.identity).inserted else { throw invalid() }
            let size = UInt64(item.rawBytes?.count ?? 0)
            guard size <= maximumBytes - bytes else { throw invalid() }
            bytes += size
            records.append(record(item))
        }
        try requireBudget(records, rawBytes: bytes, checkCancellation: checkCancellation)
        return .init(evidence: ordered, records: records)
    }

    public static func encode(
        _ projection: DesktopNativeSourceDocument.Projection, allowSensitiveContent: Bool = false,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Data {
        let verified = try project(
            projection.evidence, allowSensitiveContent: allowSensitiveContent, checkCancellation: checkCancellation
        )
        let data = try DataMigrationCoding.encoder.encode(verified.records)
        try checkCancellation()
        return data
    }

    public static func decode(
        _ data: Data, allowSensitiveContent: Bool = false,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeSourceDocument.Projection {
        try requireOptIn(allowSensitiveContent)
        let value: AnyCodable
        do {
            try JSONMemberPreflight.validate(
                data, limits: limits, checkCancellation: checkCancellation, invalid: invalid
            )
            value = try JSONDecoder().decode(AnyCodable.self, from: data)
        } catch is DecodingError { throw invalid() }
        guard case .array(let values) = value.storage else { throw invalid() }
        var evidence: [DesktopNativeSourceDocument.Evidence] = []
        var bytes: UInt64 = 0
        for value in values {
            try checkCancellation()
            guard case .object(let object) = value, Set(object.keys) == ["id", "kind", "value"],
                  case .string(let id) = object["id"], case .string(let kind) = object["kind"],
                  kind == recordKind, let body = object["value"] else { throw invalid() }
            let item = try decodeBody(body)
            guard item.identity == id, UInt64(item.rawBytes?.count ?? 0) <= maximumBytes - bytes else {
                throw invalid()
            }
            bytes += UInt64(item.rawBytes?.count ?? 0)
            evidence.append(item)
        }
        guard UInt64(data.count) <= maximumBytes - bytes else { throw invalid() }
        return try project(evidence, allowSensitiveContent: true, checkCancellation: checkCancellation)
    }

    public static func decode(
        _ record: DataMigrationRecord, category: DataMigrationCategory = .vocabulary,
        allowSensitiveContent: Bool = false,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DesktopNativeSourceDocument.Evidence {
        try requireOptIn(allowSensitiveContent)
        try checkCancellation()
        guard category == .vocabulary, record.kind == recordKind, record.date == nil, record.file == nil,
              record.digest == nil, record.revision == nil else { throw invalid() }
        let item = try decodeBody(record.value.storage)
        guard record.id == item.identity else { throw invalid() }
        _ = try project([item], allowSensitiveContent: true, checkCancellation: checkCancellation)
        return item
    }

    private static func record(_ item: DesktopNativeSourceDocument.Evidence) -> DataMigrationRecord {
        var body: [String: AnyCodable.JSONValue] = [
            "schemaVersion": .int(1), "sourcePlatform": .string(item.platform.rawValue),
            "sourceRoot": .string(item.source.root), "sourcePath": .string(item.source.path),
            "provenance": .string(item.source.provenance), "isPresent": .bool(item.rawBytes != nil)
        ]
        if let data = item.rawBytes {
            body["rawEncoding"] = .string("base64")
            body["rawBytes"] = .string(data.base64EncodedString())
        }
        return .init(id: item.identity, kind: recordKind, value: AnyCodable(.object(body)))
    }

    private static func decodeBody(_ value: AnyCodable.JSONValue) throws -> DesktopNativeSourceDocument.Evidence {
        guard case .object(let body) = value, case .int(1) = body["schemaVersion"],
              case .string(let platformName) = body["sourcePlatform"],
              let platform = DesktopNativeSourceDocument.Platform(rawValue: platformName),
              case .string(let root) = body["sourceRoot"], case .string(let path) = body["sourcePath"],
              case .string(let provenance) = body["provenance"],
              let source = DesktopNativeSourceDocument.Source.allCases.first(where: {
                  $0.root == root && $0.path == path && $0.provenance == provenance
              }),
              case .bool(let present) = body["isPresent"] else { throw invalid() }
        let expected = present ? header.union(["rawEncoding", "rawBytes"]) : header
        guard Set(body.keys) == expected else { throw invalid() }
        var data: Data?
        if present {
            guard case .string("base64") = body["rawEncoding"], case .string(let text) = body["rawBytes"] else {
                throw invalid()
            }
            let length = UInt64(text.utf8.count)
            guard length <= maximumBytes, length % 4 == 0 else { throw invalid() }
            var decodedSize = length / 4 * 3
            if text.hasSuffix("=") { decodedSize -= 1 }
            if text.hasSuffix("==") { decodedSize -= 1 }
            try admitSizes([decodedSize], encodedHeaderBytes: 0)
            guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else { throw invalid() }
            data = bytes
        }
        return .init(platform: platform, source: source, rawBytes: data)
    }

    private static func requireBudget(
        _ records: [DataMigrationRecord], rawBytes: UInt64, checkCancellation: () throws -> Void
    ) throws {
        try checkCancellation()
        let data = try DataMigrationCoding.encoder.encode(records)
        guard UInt64(data.count) <= maximumBytes - rawBytes else { throw invalid() }
        try JSONMemberPreflight.validate(
            data, limits: limits, checkCancellation: checkCancellation, invalid: invalid
        )
    }

    private static func requireOptIn(_ allowed: Bool) throws {
        guard allowed else {
            throw DataMigrationError.invalid(
                "Potentially sensitive native source preservation requires explicit opt-in."
            )
        }
    }

    static func admitSizes(_ rawSizes: [UInt64], encodedHeaderBytes: UInt64) throws {
        guard encodedHeaderBytes <= maximumBytes else { throw invalid() }
        var total = encodedHeaderBytes
        for size in rawSizes {
            guard size <= maximumBytes - total else { throw invalid() }
            total += size
            // Canonical encoding does not escape base64 characters; headers already include the empty string.
            let encoded = ((size + 2) / 3) * 4
            guard encoded <= maximumBytes - total else { throw invalid() }
            total += encoded
        }
    }

    private static func invalid() -> DataMigrationError {
        .invalid("Invalid or unbounded native source document envelope.")
    }
}
