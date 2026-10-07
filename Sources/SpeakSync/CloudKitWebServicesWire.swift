import Foundation

// JSON shapes from Apple's CloudKit Web Services Reference: the record, zone ID,
// record field and error dictionaries, and the request bodies this client sends.

struct CloudKitWebZoneID: Codable, Equatable, Sendable {
    var zoneName: String
    var ownerRecordName: String?

    init(zoneName: String, ownerRecordName: String? = nil) {
        self.zoneName = zoneName
        self.ownerRecordName = ownerRecordName
    }
}

/// A decoded record field value. Typed values use the schema's field types;
/// a value without a `type` keeps its JSON kind; other types are preserved as
/// unsupported so they are never rewritten.
enum CloudKitWebFieldValue: Equatable, Sendable {
    case typed(SyncFieldValue)
    case untypedString(String)
    case untypedNumber(Double)
    case null
    case unsupported(type: String)
}

enum CloudKitWebTimestamp {
    /// Milliseconds since 1970, the Date/Time wire unit.
    static func milliseconds(_ date: Date) -> Int64? {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite, abs(value) < 9.0e15 else { return nil }
        return Int64(value)
    }

    static func date(milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

struct CloudKitWebField: Decodable, Equatable, Sendable {
    let value: CloudKitWebFieldValue

    private enum CodingKeys: String, CodingKey {
        case value
        case type
    }

    init(_ value: CloudKitWebFieldValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        guard container.contains(.value), try !container.decodeNil(forKey: .value) else {
            value = .null
            return
        }
        guard let type else {
            if let text = try? container.decode(String.self, forKey: .value) {
                value = .untypedString(text)
            } else if let number = try? container.decode(Double.self, forKey: .value) {
                value = .untypedNumber(number)
            } else {
                value = .unsupported(type: "")
            }
            return
        }
        value = Self.typedValue(type: type, in: container) ?? .unsupported(type: type)
    }

    private static func typedValue(
        type: String,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> CloudKitWebFieldValue? {
        switch type {
        case "STRING":
            return (try? container.decode(String.self, forKey: .value)).map { .typed(.string($0)) }
        case "INT64":
            return integer(in: container).map { .typed(.int64($0)) }
        case "DOUBLE":
            return number(in: container).map { .typed(.double($0)) }
        case "TIMESTAMP":
            return number(in: container).map { .typed(.timestamp(CloudKitWebTimestamp.date(milliseconds: $0))) }
        case "BYTES":
            let text = try? container.decode(String.self, forKey: .value)
            return text.flatMap { Data(base64Encoded: $0) }.map { .typed(.bytes($0)) }
        default:
            return nil
        }
    }

    /// Accepts a JSON number or, when `numbersAsStrings` was requested, a string.
    private static func integer(in container: KeyedDecodingContainer<CodingKeys>) -> Int64? {
        if let integer = try? container.decode(Int64.self, forKey: .value) { return integer }
        return number(in: container).flatMap { Int64(exactly: $0) }
    }

    private static func number(in container: KeyedDecodingContainer<CodingKeys>) -> Double? {
        if let number = try? container.decode(Double.self, forKey: .value) { return number }
        return (try? container.decode(String.self, forKey: .value)).flatMap(Double.init)
    }
}

/// A record dictionary from a change feed, lookup or modify response.
struct CloudKitWebRecord: Decodable, Equatable, Sendable {
    let recordName: String
    let recordType: String?
    let recordChangeTag: String?
    let deleted: Bool
    let fields: [String: CloudKitWebField]

    private enum CodingKeys: String, CodingKey {
        case recordName
        case recordType
        case recordChangeTag
        case deleted
        case fields
    }

    init(
        recordName: String,
        recordType: String?,
        recordChangeTag: String?,
        deleted: Bool = false,
        fields: [String: CloudKitWebField] = [:]
    ) {
        self.recordName = recordName
        self.recordType = recordType
        self.recordChangeTag = recordChangeTag
        self.deleted = deleted
        self.fields = fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordName = try container.decode(String.self, forKey: .recordName)
        recordType = try container.decodeIfPresent(String.self, forKey: .recordType)
        recordChangeTag = try container.decodeIfPresent(String.self, forKey: .recordChangeTag)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        fields = try container.decodeIfPresent([String: CloudKitWebField].self, forKey: .fields) ?? [:]
    }

    /// Whether the server holds any value for `key`, so clearing it needs an explicit null.
    func hasValue(forKey key: String) -> Bool {
        switch fields[key]?.value {
        case nil, .null?: return false
        default: return true
        }
    }
}

extension CloudKitWebRecord: SyncRecordFieldReading {
    var syncRecordName: String { recordName }
    var syncRecordType: String { recordType ?? "" }

    func string(forKey key: String) -> String? {
        switch fields[key]?.value {
        case .typed(.string(let text))?, .untypedString(let text)?: return text
        default: return nil
        }
    }

    func int(forKey key: String) -> Int? {
        switch fields[key]?.value {
        case .typed(let value)?: return value.bridgedInt
        case .untypedNumber(let number)?: return Int(exactly: number)
        default: return nil
        }
    }

    func double(forKey key: String) -> Double? {
        switch fields[key]?.value {
        case .typed(let value)?: return value.bridgedDouble
        case .untypedNumber(let number)?: return number
        default: return nil
        }
    }

    func date(forKey key: String) -> Date? {
        switch fields[key]?.value {
        case .typed(.timestamp(let date))?: return date
        case .untypedNumber(let milliseconds)?: return CloudKitWebTimestamp.date(milliseconds: milliseconds)
        default: return nil
        }
    }

    func data(forKey key: String) -> Data? {
        switch fields[key]?.value {
        case .typed(.bytes(let bytes))?: return bytes
        case .untypedString(let text)?: return Data(base64Encoded: text)
        default: return nil
        }
    }

    func bool(forKey key: String) -> Bool? {
        switch fields[key]?.value {
        case .typed(let value)?: return value.bridgedBool
        case .untypedNumber(let number)?: return SyncFieldValue.double(number).bridgedBool
        default: return nil
        }
    }
}

/// One element of a `records` array: a record dictionary or an error dictionary.
enum CloudKitWebRecordResult: Decodable, Equatable, Sendable {
    case record(CloudKitWebRecord)
    case failure(CloudKitWebServerError)

    private enum ProbeKeys: String, CodingKey {
        case serverErrorCode
    }

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: ProbeKeys.self)
        if probe.contains(.serverErrorCode) {
            self = .failure(try CloudKitWebServerError(from: decoder))
        } else {
            self = .record(try CloudKitWebRecord(from: decoder))
        }
    }

    var recordName: String? {
        switch self {
        case .record(let record): return record.recordName
        case .failure(let error): return error.recordName
        }
    }
}

struct CloudKitWebRecordsResponse: Decodable {
    let records: [CloudKitWebRecordResult]
}

/// One zone's page of the `changes/zone` feed.
struct CloudKitWebZoneChanges: Equatable, Sendable {
    var records: [CloudKitWebRecordResult]
    var syncToken: String?
    var moreComing: Bool
}

enum CloudKitWebZoneResult: Decodable {
    case changes(zoneName: String?, CloudKitWebZoneChanges)
    case failure(zoneName: String?, CloudKitWebServerError)

    private enum CodingKeys: String, CodingKey {
        case zoneID
        case syncToken
        case moreComing
        case records
        case serverErrorCode
    }

    var zoneName: String? {
        switch self {
        case .changes(let zoneName, _), .failure(let zoneName, _): return zoneName
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let zoneName = try container.decodeIfPresent(CloudKitWebZoneID.self, forKey: .zoneID)?.zoneName
        if container.contains(.serverErrorCode) {
            self = .failure(zoneName: zoneName, try CloudKitWebServerError(from: decoder))
            return
        }
        let changes = CloudKitWebZoneChanges(
            records: try container.decodeIfPresent([CloudKitWebRecordResult].self, forKey: .records) ?? [],
            syncToken: try container.decodeIfPresent(String.self, forKey: .syncToken),
            moreComing: try container.decodeIfPresent(Bool.self, forKey: .moreComing) ?? false
        )
        self = .changes(zoneName: zoneName, changes)
    }
}

struct CloudKitWebZonesResponse: Decodable {
    let zones: [CloudKitWebZoneResult]
}

/// `users/caller` documents `{"users": [identity]}`; a bare identity is also read.
struct CloudKitWebCallerResponse: Decodable {
    let userRecordName: String?

    private struct Identity: Decodable {
        let userRecordName: String?
    }

    private enum CodingKeys: String, CodingKey {
        case users
        case userRecordName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let users = try container.decodeIfPresent([Identity].self, forKey: .users)
        if let listed = users?.first?.userRecordName {
            userRecordName = listed
        } else {
            userRecordName = try container.decodeIfPresent(String.self, forKey: .userRecordName)
        }
    }
}
