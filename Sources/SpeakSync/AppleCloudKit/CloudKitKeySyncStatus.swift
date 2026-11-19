import Foundation

public struct CloudKitKeySyncStatus: Equatable, Sendable {
    public var isEnabled: Bool
    public var isCloudAvailable: Bool
    public var isSyncing: Bool
    public var lastSyncTime: Date?
    public var lastErrorDescription: String?

    public init(
        isEnabled: Bool = false,
        isCloudAvailable: Bool = false,
        isSyncing: Bool = false,
        lastSyncTime: Date? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.isCloudAvailable = isCloudAvailable
        self.isSyncing = isSyncing
        self.lastSyncTime = lastSyncTime
        self.lastErrorDescription = lastErrorDescription
    }

    public var message: String {
        if let lastErrorDescription { return lastErrorDescription }
        if !isCloudAvailable { return "CloudKit unavailable" }
        if !isEnabled { return "Off" }
        if isSyncing { return "Syncing…" }
        if let lastSyncTime {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: lastSyncTime, relativeTo: Date()))"
        }
        return "Ready"
    }
}
