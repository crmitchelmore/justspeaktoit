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
