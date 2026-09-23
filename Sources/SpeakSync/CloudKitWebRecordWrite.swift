import Foundation

/// Builds record writes with the semantics of a native `CKRecord` save.
enum CloudKitWebRecordWrite {
    /// A new record holds only the fields that have values. `create` fails with
    /// `EXISTS` if another client created the record first.
    static func create(
        recordName: String,
        recordType: String,
        assignments: SyncRecordFieldAssignments
    ) throws -> CloudKitWebRecordOperation {
        try validate(assignments)
        var fields: [String: CloudKitWebFieldPayload] = [:]
        for assignment in assignments {
            if let value = assignment.value {
                fields[assignment.key] = CloudKitWebFieldPayload(value: value)
            }
        }
        let record = CloudKitWebRecordOperation.Record(
            recordName: recordName,
            recordType: recordType,
            recordChangeTag: nil,
            fields: fields
        )
        return CloudKitWebRecordOperation(operationType: .create, record: record)
    }

    /// Mutates the fetched record, as the native mappers do: every assigned
    /// field is written, a cleared field is sent as an explicit null only where
    /// the server holds a value, and fields this client does not write are left
    /// untouched. The fetched change tag makes a concurrent write fail with
    /// `CONFLICT` instead of being overwritten.
    static func update(
        existing: CloudKitWebRecord,
        recordType: String,
        assignments: SyncRecordFieldAssignments
    ) throws -> CloudKitWebRecordOperation {
        guard let changeTag = existing.recordChangeTag, !changeTag.isEmpty else {
            throw CloudKitWebServicesError.invalidResponse("A fetched record had no change tag.")
        }
        try validate(assignments)
        var fields: [String: CloudKitWebFieldPayload] = [:]
        for assignment in assignments {
            if let value = assignment.value {
                fields[assignment.key] = CloudKitWebFieldPayload(value: value)
            } else if existing.hasValue(forKey: assignment.key) {
                fields[assignment.key] = CloudKitWebFieldPayload(value: nil)
            }
        }
        let record = CloudKitWebRecordOperation.Record(
            recordName: existing.recordName,
            recordType: existing.recordType ?? recordType,
            recordChangeTag: changeTag,
            fields: fields
        )
        return CloudKitWebRecordOperation(operationType: .update, record: record)
    }

    /// Deletes by record name without a change tag, as a native
    /// `deleteRecord(withID:)` does.
    static func forceDelete(recordName: String) -> CloudKitWebRecordOperation {
        let record = CloudKitWebRecordOperation.Record(
            recordName: recordName,
            recordType: nil,
            recordChangeTag: nil,
            fields: nil
        )
        return CloudKitWebRecordOperation(operationType: .forceDelete, record: record)
    }

    /// Rejects values JSON or the Date/Time unit cannot carry, so one bad entry
    /// fails alone instead of failing its whole request.
    private static func validate(_ assignments: SyncRecordFieldAssignments) throws {
        for assignment in assignments {
            switch assignment.value {
            case .double(let number)? where !number.isFinite:
                throw SyncError.encodingFailed
            case .timestamp(let date)? where CloudKitWebTimestamp.milliseconds(date) == nil:
                throw SyncError.encodingFailed
            default:
                continue
            }
        }
    }
}
