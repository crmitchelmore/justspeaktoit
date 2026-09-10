#if os(iOS)
import Foundation
import SpeakCore

/// The containing app's side of keyboard delivery (issues #1002, #1003).
///
/// Every completed capture — Action Button, Siri, Shortcuts, the app itself, a
/// watch import — leaves the transcript here for the keyboard to pick up. Two
/// shapes come out of `KeyboardDeliveryPlanner`:
///
/// - The keyboard is demonstrably on screen right now, so the words go into
///   that field (`.targetedInsert`, and only into that exact document).
/// - It is not, so the words wait as a one-tap chip for up to ten minutes
///   (`.latePickup`).
///
/// This never changes where the transcript otherwise goes. The clipboard, the
/// History entry and the Live Activity are untouched, so a lost or expired
/// offer costs the user nothing they had before — and clipboard ownership
/// stays entirely with #934 / PR #1031.
@MainActor
public enum KeyboardDeliveryPublisher {
    /// Publishes a completed transcript for keyboard delivery. A no-op without
    /// Full Access, where the App Group is unavailable.
    @discardableResult
    public static func publish(
        transcript: String,
        source: KeyboardPickupOffer.Source,
        store: KeyboardDeliveryStore = .shared,
        now: Date = Date()
    ) -> KeyboardPickupOffer? {
        guard store.isAvailable else { return nil }
        guard let offer = KeyboardDeliveryPlanner.plan(
            transcript: transcript,
            source: source,
            target: store.openTarget(now: now),
            now: now
        ) else {
            return nil
        }
        return store.publishOffer(offer)
    }

    /// How long a stop waits for the keyboard to claim a targeted offer.
    ///
    /// The extension polls the App Group every 500 ms (and, once #990 lands,
    /// is woken by a Darwin notification), so a keyboard that is genuinely
    /// still open in the same document claims well inside this. The budget is
    /// spent only on the one path where a targeted offer was written, and the
    /// stop already holds a background assertion for the clipboard flush.
    public static let insertionConfirmationTimeout = Duration.milliseconds(1500)
    public static let insertionPollInterval = Duration.milliseconds(100)

    /// Resolves what actually became of `offer`, rather than what publishing
    /// it was meant to achieve.
    ///
    /// A published offer is a message in the App Group, not a delivery. For a
    /// `.targetedInsert` this waits for the extension to write a claim naming
    /// the offer — which `KeyboardViewModel.deliver(_:offerID:)` does only
    /// after the text document proxy accepted the text, and which for a
    /// targeted offer cannot come from a user dismissal because a targeted
    /// offer is never shown as a dismissible chip. So the claim is evidence of
    /// an insertion, and its absence means the words are not in the field and
    /// the capture must fall back to the clipboard.
    public static func awaitOutcome(
        for offer: KeyboardPickupOffer?,
        store: KeyboardDeliveryStore = .shared,
        timeout: Duration = insertionConfirmationTimeout,
        pollInterval: Duration = insertionPollInterval,
        clock: ContinuousClock = ContinuousClock()
    ) async -> CaptureReceiptBuilder.KeyboardOfferOutcome {
        guard let offer else { return .notOffered }
        guard offer.mode == .targetedInsert else { return .latePickupWaiting }

        let deadline = clock.now.advanced(by: timeout)
        while true {
            if store.claim()?.offerID == offer.offerID { return .insertedInField }
            guard clock.now < deadline else { return .targetedButNotInserted }
            try? await Task.sleep(for: pollInterval, clock: clock)
            if Task.isCancelled { break }
        }
        return store.claim()?.offerID == offer.offerID ? .insertedInField : .targetedButNotInserted
    }

    /// What a hardware trigger should do about a keyboard-owned dictation
    /// before running its own start/stop logic (issue #1002).
    public static func sessionRouting(
        handoffStore: KeyboardHandoffStore = .shared,
        now: Date = Date()
    ) -> KeyboardSessionRouting.Decision {
        KeyboardSessionRouting.decision(handoff: handoffStore.activeRecord(now: now), now: now)
    }
}
#endif
