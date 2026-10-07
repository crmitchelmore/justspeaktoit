import CloudKit
import Foundation
import SpeakCore
#if os(macOS)
import Security
#endif

/// Configuration for CloudKit sync operations.
///
/// Schema names forward to the portable `SyncSchema`, which the CloudKit Web
/// Services transport shares; this type adds the native container and database.
public enum SyncConfiguration {
    /// The CloudKit container identifier.
    #if os(iOS)
    public static let containerIdentifier = SyncContainerFamily.iOS.containerIdentifier(in: .current)
    #elseif os(macOS)
    public static let containerIdentifier = SyncContainerFamily.macOS.containerIdentifier(in: .current)
    #endif

    /// The custom zone name for transcription history.
    public static let zoneName = SyncSchema.zoneName

    /// The record type for transcription history entries.
    public static let recordType = SyncSchema.History.recordType

    /// UserDefaults key for storing the last sync token.
    public static let syncTokenKey = "speak.sync.serverChangeToken"

    /// UserDefaults key for tracking zone creation.
    public static let zoneCreatedKey = "speak.sync.zoneCreated"

    /// UserDefaults key for tracking subscription creation.
    public static let subscriptionCreatedKey = "speak.sync.subscriptionCreated"

    /// UserDefaults key for this device's iCloud data sync switch, which covers
    /// History and, on Mac, Compare Models results. Encrypted API-Key Sync has
    /// its own opt-in. Absent means on, so a device that synced before the
    /// switch existed keeps syncing until the user turns it off.
    public static let dataSyncEnabledKey = "speak.sync.iCloudDataSyncEnabled"

    /// Whether this device takes part in iCloud data sync. Off keeps History
    /// and comparison results on this device only.
    public static func isDataSyncEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: dataSyncEnabledKey) as? Bool ?? true
    }

    /// The database subscription whose pushes announce a history change.
    public static let historySubscriptionID = SyncSchema.History.subscriptionID

    /// Maximum number of entries to sync in a single batch.
    public static let batchSize = SyncSchema.batchSize

    /// The CloudKit container.
    /// Returns `nil` when CloudKit entitlements are missing (Developer ID builds).
    public static var container: CKContainer? {
        guard hasCloudKitEntitlement else { return nil }
        return CKContainer(identifier: containerIdentifier)
    }

    /// Whether this app build has CloudKit entitlements.
    /// Developer ID Sparkle builds may omit CloudKit entitlements.
    static var hasCloudKitEntitlement: Bool {
#if os(iOS)
        // iOS App Store / TestFlight builds always ship with the managed
        // provisioning profile that carries the CloudKit entitlements, and the
        // SecTask entitlement-introspection APIs (SecTaskCreateFromSelf /
        // SecTaskCopyValueForEntitlement) are not part of the public iOS SDK.
        // So assume availability on iOS and only probe on macOS, where Developer
        // ID (Sparkle) builds may legitimately omit CloudKit.
        return true
#elseif os(macOS)
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
        return false
#endif
    }

    /// The private database for user's transcription data.
    /// Returns `nil` when CloudKit entitlements are missing.
    public static var privateDatabase: CKDatabase? {
        container?.privateCloudDatabase
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
