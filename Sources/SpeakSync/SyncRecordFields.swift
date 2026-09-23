import Foundation

/// One value in the existing CloudKit schema. The production records use only
/// these field types: String, Int(64), Double, Date/Time and Bytes.
public enum SyncFieldValue: Equatable, Sendable {
    case string(String)
    case int64(Int64)
    case double(Double)
    case timestamp(Date)
    case bytes(Data)
}

/// Read access to one record's fields.
///
/// The accessors follow the dynamic typing of `record[key] as? T` on a
/// `CKRecord`, so the native adapter and a CloudKit Web Services record decode
/// the same stored value to the same model value.
protocol SyncRecordFieldReading {
    var syncRecordName: String { get }
    var syncRecordType: String { get }
    func string(forKey key: String) -> String?
    func int(forKey key: String) -> Int?
    func double(forKey key: String) -> Double?
    func date(forKey key: String) -> Date?
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool?
}

/// Write access to one record's fields. Setting `nil` removes the value, as
/// assigning `nil` through a `CKRecord` subscript does.
protocol SyncRecordFieldWriting {
    mutating func set(_ value: SyncFieldValue?, forKey key: String)
}

extension SyncFieldValue {
    /// `NSNumber` bridging rules for `as? Int`: exact integral values only.
    var bridgedInt: Int? {
        switch self {
        case .int64(let value): return Int(exactly: value)
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    /// `NSNumber` bridging rules for `as? Double`: exactly representable values.
    var bridgedDouble: Double? {
        switch self {
        case .double(let value): return value
        case .int64(let value): return Double(exactly: value)
        default: return nil
        }
    }

    /// `NSNumber` bridging rules for `as? Bool`: only zero and one.
    var bridgedBool: Bool? {
        switch self {
        case .int64(0): return false
        case .int64(1): return true
        case .double(let value) where value == 0: return false
        case .double(let value) where value == 1: return true
        default: return nil
        }
    }
}
