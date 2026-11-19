import Foundation

/// Observable sync state for UI updates.
@MainActor
public final class SyncState: ObservableObject {
    /// Whether sync is currently in progress.
    @Published public var isSyncing = false

    /// Last successful sync time.
    @Published public var lastSyncTime: Date?

    /// Current sync error, if any.
    @Published public var error: Error?

    /// Number of entries pending upload.
    @Published public var pendingUploadCount = 0

    /// Number of entries pending download.
    @Published public var pendingDownloadCount = 0

    /// Whether iCloud is available.
    @Published public var isCloudAvailable = false

    /// User-friendly status message.
    public var statusMessage: String {
        if !isCloudAvailable {
            return "iCloud unavailable"
        }
        if isSyncing {
            return "Syncing..."
        }
        if let error {
            return "Sync error: \(error.localizedDescription)"
        }
        if let lastSync = lastSyncTime {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
        }
        return "Not synced"
    }

    public init() {}

    /// Writes exactly the fields the shared coordinator assigned, in its order,
    /// so observers see the same sequence of changes the engine always published.
    func apply(_ status: HistorySyncStatus, changed field: HistorySyncStatus.Field) {
        switch field {
        case .isSyncing: isSyncing = status.isSyncing
        case .lastSyncTime: lastSyncTime = status.lastSyncTime
        case .error: error = status.error
        case .pendingUploadCount: pendingUploadCount = status.pendingUploadCount
        case .pendingDownloadCount: pendingDownloadCount = status.pendingDownloadCount
        case .isCloudAvailable: isCloudAvailable = status.isCloudAvailable
        }
    }
}
