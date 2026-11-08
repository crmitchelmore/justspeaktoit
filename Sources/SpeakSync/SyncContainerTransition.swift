import Foundation

/// Forgets sync state that belongs to a previous CloudKit container (#1119).
///
/// Change tokens, zone/subscription markers and acknowledged-record sets are
/// only meaningful in the database that issued them. When a build moves to
/// another container, clearing them makes every device re-push its local
/// History into the new container, and the key-sync account marker is cleared
/// so the existing account-change reset turns key sync off until the user
/// enables it again there. Nothing in either container is deleted.
public enum SyncContainerTransition {
    /// The container whose state this device's defaults currently describe.
    public static let lastContainerKey = "speak.sync.containerIdentifier"

    static let containerScopedKeys = [
        SyncConfiguration.syncTokenKey,
        SyncConfiguration.zoneCreatedKey,
        SyncConfiguration.subscriptionCreatedKey,
        ComparisonSyncEngine.syncTokenKey,
        CloudKitKeySync.accountIdentifierKey
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
            legacy: SyncConfiguration.legacyFamily.containerIdentifier(in: .current),
            defaults: defaults,
            additionalKeys: additionalKeys
        )
    }
}
