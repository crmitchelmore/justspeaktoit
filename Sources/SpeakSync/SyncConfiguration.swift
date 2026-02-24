import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

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

    /// Whether this app build has CloudKit entitlements.
    /// Developer ID Sparkle builds may omit CloudKit entitlements.
    static var hasCloudKitEntitlement: Bool {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else {
            return false
        }

        let services = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
        ) as? [String]
        let hasCloudKitService = services?.contains("CloudKit") == true

        let containers = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        ) as? [String]
        let hasContainerIdentifier = containers?.contains(containerIdentifier) == true
        return hasCloudKitService && hasContainerIdentifier
#else
        return true
#endif
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
