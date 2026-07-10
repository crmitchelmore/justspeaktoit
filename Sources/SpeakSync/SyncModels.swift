import Foundation
@_exported import SpeakCore

/// A platform-agnostic transcription history entry for CloudKit sync.
/// Both iOS and macOS map their native history types to/from this model.

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
}

/// Errors that can occur during sync.
public enum SyncError: LocalizedError {
    case cloudUnavailable
    case cloudKit(Error)
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            return "iCloud is not available. Please sign in to iCloud in Settings."
        case .cloudKit(let error):
            return "CloudKit error: \(error.localizedDescription)"
        case .encodingFailed:
            return "Failed to encode data for sync"
        case .decodingFailed:
            return "Failed to decode synced data"
        }
    }
}
