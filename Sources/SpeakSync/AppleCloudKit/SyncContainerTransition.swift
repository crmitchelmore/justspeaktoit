import CloudKit
import Foundation

/// Forgets sync state that belongs to a previous CloudKit container (#1119).
///
/// Change tokens, zone/subscription markers and acknowledged-record sets are
/// only meaningful in the database that issued them. When a build moves to
/// another container, clearing them makes every device re-push its local
/// History into the new container. The key-sync account fingerprint is kept
/// aside rather than deleted: CloudKit user record names differ per
/// container, so `CloudKitKeySync` compares it with the old container's
/// account to tell a container move from an iCloud account change. Nothing in
/// either container is deleted.
public enum SyncContainerTransition {
    /// The container whose state this device's defaults currently describe.
    public static let lastContainerKey = "speak.sync.containerIdentifier"

    /// Set once the one-time History copy from the legacy container finished.
    public static let historyMigrationCompletedKey = "speak.sync.legacyContainerHistoryCopied"

    static let containerScopedKeys = [
        SyncConfiguration.syncTokenKey,
        SyncConfiguration.zoneCreatedKey,
        SyncConfiguration.subscriptionCreatedKey,
        ComparisonSyncEngine.syncTokenKey,
        CloudKitKeySync.syncTokenKey,
        KeySyncCloudOperations.zoneCreatedKey,
        KeySyncCloudOperations.subscriptionCreatedKey
    ]

    /// Clears container-scoped state when `current` differs from the
    /// container last recorded, or from `legacy` on devices that predate the
    /// record. Returns whether anything was reset.
    @discardableResult
    public static func resetIfContainerChanged(
        to current: String,
        legacy: String,
        defaults: UserDefaults,
        additionalKeys: [String] = []
    ) -> Bool {
        let previous = defaults.string(forKey: lastContainerKey) ?? legacy
        defer { defaults.set(current, forKey: lastContainerKey) }
        guard previous != current else { return false }
        for key in containerScopedKeys + additionalKeys {
            defaults.removeObject(forKey: key)
        }
        if let account = defaults.string(forKey: CloudKitKeySync.accountIdentifierKey) {
            defaults.set(account, forKey: CloudKitKeySync.legacyAccountIdentifierKey)
            defaults.removeObject(forKey: CloudKitKeySync.accountIdentifierKey)
        }
        return true
    }

    /// The same reset for this build's configured container.
    @discardableResult
    public static func resetIfContainerChanged(
        defaults: UserDefaults = .standard,
        additionalKeys: [String] = []
    ) -> Bool {
        resetIfContainerChanged(
            to: SyncConfiguration.containerIdentifier,
            legacy: SyncConfiguration.legacyContainerIdentifier ?? SyncConfiguration.containerIdentifier,
            defaults: defaults,
            additionalKeys: additionalKeys
        )
    }

    /// Whether `error` says the zone does not exist, which for the legacy
    /// container means there is nothing to copy.
    static func isMissingZone(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if [.zoneNotFound, .userDeletedZone].contains(error.code) { return true }
        guard let partial = error.partialErrorsByItemID?.values, !partial.isEmpty else { return false }
        return partial.allSatisfy { isMissingZone($0) }
    }
}
