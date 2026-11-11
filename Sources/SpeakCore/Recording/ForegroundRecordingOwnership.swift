import Foundation

/// Process-local ownership, separate from the recording flag displayed by widgets.
/// AudioRecordingIntent runs in the app process; a persisted display snapshot must
/// never grant microphone acquisition while the foreground owner is still settling.
@MainActor
public final class ForegroundRecordingOwnership {
    public static let shared = ForegroundRecordingOwnership()
    private var runID: UUID?

    public init() {}

    public var isOwned: Bool { runID != nil }

    public enum OwnershipError: LocalizedError {
        case recordingInApp

        public var errorDescription: String? {
            "A recording is already in progress in the app. Use the in-app stop button."
        }
    }

    public func requireUnowned() throws {
        if isOwned { throw OwnershipError.recordingInApp }
    }

    public func claim(_ runID: UUID) -> Bool {
        guard self.runID == nil else { return false }
        self.runID = runID
        return true
    }

    public func release(_ runID: UUID) {
        guard self.runID == runID else { return }
        self.runID = nil
    }
}
