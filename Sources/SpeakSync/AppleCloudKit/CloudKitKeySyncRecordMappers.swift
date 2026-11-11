import CloudKit
import Foundation
import SpeakCore

public enum EncryptedSecretRecordMapper {
    public static let recordType = SyncSchema.EncryptedSecret.recordType

    public static func recordName(for identifier: String) -> String {
        SyncSchema.EncryptedSecret.recordName(for: identifier)
    }

    public static func record(from secret: EncryptedSecret, existingRecord: CKRecord? = nil) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: recordName(for: secret.identifier),
            zoneID: SyncConfiguration.zoneID
        )
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID)
        var fields = CloudKitRecordFields(record)
        fields.apply(EncryptedSecretRecordCodec.assignments(for: secret))
        return record
    }

    public static func secret(from record: CKRecord) -> EncryptedSecret? {
        EncryptedSecretRecordCodec.secret(from: CloudKitRecordFields(record))
    }
}

enum KeySyncMetadataRecordMapper {
    static var recordID: CKRecord.ID {
        CKRecord.ID(recordName: SyncSchema.KeySyncMetadata.recordName, zoneID: SyncConfiguration.zoneID)
    }

    static func record(
        from metadata: KeySyncMetadata,
        updatedAt: Date,
        existingRecord: CKRecord? = nil
    ) -> CKRecord {
        let record = existingRecord ?? CKRecord(recordType: SyncSchema.KeySyncMetadata.recordType, recordID: recordID)
        var fields = CloudKitRecordFields(record)
        fields.apply(KeySyncMetadataRecordCodec.assignments(for: metadata, updatedAt: updatedAt))
        return record
    }

    static func metadata(from record: CKRecord) -> KeySyncMetadata? {
        KeySyncMetadataRecordCodec.metadata(from: CloudKitRecordFields(record))
    }
}
