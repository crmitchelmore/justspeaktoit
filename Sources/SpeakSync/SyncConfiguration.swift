import CloudKit
import Foundation

/// Configuration for CloudKit sync operations.
public enum SyncConfiguration {
    /// The CloudKit container identifier.
    public static let containerIdentifier = "iCloud.com.justspeaktoit"

    /// The custom zone name for transcription history.
    public static let zoneName = "TranscriptionHistoryZone"

    /// The record type for transcription history entries.
    public static let recordType = "TranscriptionHistory"

    /// UserDefaults key for storing the last sync token.
    public static let syncTokenKey = "speak.sync.serverChangeToken"

    /// UserDefaults key for tracking zone creation.
    public static let zoneCreatedKey = "speak.sync.zoneCreated"

    /// UserDefaults key for tracking subscription creation.
    public static let subscriptionCreatedKey = "speak.sync.subscriptionCreated"

    /// Maximum number of entries to sync in a single batch.
    public static let batchSize = 100

    /// The CloudKit container.
    public static var container: CKContainer {
        CKContainer(identifier: containerIdentifier)
    }

    /// The private database for user's transcription data.
    public static var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    /// The custom zone for transcription history.
    public static var recordZone: CKRecordZone {
        CKRecordZone(zoneName: zoneName)
    }

    /// The zone ID for the transcription history zone.
    public static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }
}
