import CloudKit
import Foundation

/// Presents a `CKRecord` to the shared record codecs. Reads use the same
/// `record[key] as? T` casts the native mappers always used; writes store the
/// same value types those mappers assigned.
struct CloudKitRecordFields: SyncRecordFieldReading, SyncRecordFieldWriting {
    let record: CKRecord

    init(_ record: CKRecord) {
        self.record = record
    }

    var syncRecordName: String { record.recordID.recordName }
    var syncRecordType: String { record.recordType }

    func string(forKey key: String) -> String? { record[key] as? String }
    func int(forKey key: String) -> Int? { record[key] as? Int }
    func double(forKey key: String) -> Double? { record[key] as? Double }
    func date(forKey key: String) -> Date? { record[key] as? Date }
    func data(forKey key: String) -> Data? { record[key] as? Data }
    func bool(forKey key: String) -> Bool? { record[key] as? Bool }

    func set(_ value: SyncFieldValue?, forKey key: String) {
        switch value {
        case nil:
            record[key] = nil
        case .string(let string):
            record[key] = string as CKRecordValue
        case .int64(let integer):
            // Int is 64-bit on every platform SpeakSync ships to, so this is the
            // same NSNumber the mappers stored when they assigned an `Int`.
            record[key] = Int(integer) as CKRecordValue
        case .double(let double):
            record[key] = double as CKRecordValue
        case .timestamp(let date):
            record[key] = date as CKRecordValue
        case .bytes(let data):
            record[key] = data as CKRecordValue
        }
    }
}
