#if os(iOS)
import Foundation
import SpeakCore

/// Publishes the "Continue on Mac" pointer after a capture (issue #1006).
///
/// One activity object is reused for the life of the process. `becomeCurrent()`
/// on a fresh `NSUserActivity` per capture would leave the previous ones alive
/// and racing to be advertised; updating the same object replaces the pointer
/// the Mac's Dock slot offers.
///
/// The activity is only advertised while the app is in the foreground — iOS
/// does not advertise an activity made current by a suspended background
/// intent. That is not a fallback the user needs: the transcript is already
/// going to the Mac through CloudKit history sync (issue #1007), and Handoff is
/// the shortcut, not the lane.
@MainActor
public enum TranscriptHandoffPublisher {
    private static var activity: NSUserActivity?
    /// The entry the current pointer names, so a deletion of exactly that
    /// entry can withdraw it (issue #1006).
    private static var advertisedEntryID: UUID?

    /// The entry the pointer currently advertises, or `nil` when nothing is
    /// advertised. Exposed for tests and for callers that need to reason about
    /// what a deletion has to withdraw.
    public static var currentEntryID: UUID? { advertisedEntryID }

    /// - Returns: the pointer that was published, or `nil` when there was
    ///   nothing to point at.
    @discardableResult
    public static func publish(
        entryID: UUID?,
        createdAt: Date,
        wordCount: Int,
        originPlatform: String = "ios"
    ) -> TranscriptHandoffActivity.Pointer? {
        guard let entryID, wordCount > 0 else { return nil }
        let pointer = TranscriptHandoffActivity.Pointer(
            entryID: entryID,
            createdAt: createdAt,
            wordCount: wordCount,
            originPlatform: originPlatform
        )

        let activity = activity ?? NSUserActivity(activityType: TranscriptHandoffActivity.activityType)
        Self.activity = activity
        activity.title = TranscriptHandoffActivity.title(for: pointer)
        activity.isEligibleForHandoff = true
        // The pointer is a private continuity hint, not content to index or
        // surface in Spotlight or on the public web.
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = TranscriptHandoffActivity.userInfo(for: pointer)
        activity.becomeCurrent()
        advertisedEntryID = entryID
        return pointer
    }

    /// Stops advertising the current pointer. Used when history is cleared, so
    /// a Dock item cannot outlive the entry it points at.
    public static func invalidate() {
        activity?.resignCurrent()
        activity?.invalidate()
        activity = nil
        advertisedEntryID = nil
    }

    /// Withdraws the pointer when — and only when — it names `entryID`.
    ///
    /// Deleting the advertised entry, locally or through a remote tombstone,
    /// has to stop the advertisement: otherwise the Dock keeps offering
    /// metadata for a transcript the user deliberately removed, and following
    /// it sends the Mac to an entry that no longer exists.
    public static func invalidateIfAdvertising(entryID: UUID) {
        guard advertisedEntryID == entryID else { return }
        invalidate()
    }
}
#endif
