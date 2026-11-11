#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Destination side effects of a settled capture: clipboard, shared App Group
/// state, keyboard offer, handoff and the completed Live Activity.
@MainActor
extension TranscriptionRecordingService {
    func permitsSharedCompletion(_ selection: CaptureDestinationSelection) -> Bool {
        switch selection.origin {
        case .explicitStop, .legacy: return sharedTranscriptRequested
        default: return sharesLiveTranscript
        }
    }

    func publishHandoff(entryID: UUID?, createdAt: Date, wordCount: Int, allowed: Bool) {
        guard allowed else { return }
        TranscriptHandoffPublisher.publish(entryID: entryID, createdAt: createdAt, wordCount: wordCount)
    }

    func publishKeyboardOffer(
        text: String, source: KeyboardPickupOffer.Source?, destination: HardwareTriggerDestination
    ) -> KeyboardPickupOffer? {
        guard destination != .historyOnly, let source else { return nil }
        return KeyboardDeliveryPublisher.publish(transcript: text, source: source, store: dependencies.keyboardDelivery)
    }

    func completeRecordingActivity(
        duration: Int,
        primedMessage: String,
        outcome: TranscriptionCompletionOutcome,
        resultPreview: String,
        completionMessage: String? = nil,
        identity: (copyToken: String, surfaceOwnerID: UUID)
    ) {
        if let completeOwnedActivity {
            completeOwnedActivity(
                wordCount, duration, primedMessage, outcome, resultPreview, completionMessage,
                identity.copyToken, identity.surfaceOwnerID
            )
            return
        }
        completeActivity(
            wordCount, duration, primedMessage, outcome, resultPreview, completionMessage, identity.copyToken
        )
    }

    /// Discards the temporary recording of the capture whose transcript has
    /// just been delivered. A capture whose result was never used — an
    /// abandoned finalisation, a failed stop — never reaches here, so its audio
    /// survives for recovery.
    func discardDeliveredRecording() {
        let session = deliveringSession
        deliveringSession = nil
        session?.discardTemporaryRecording()
    }

    /// What the pasteboard lane of a stop produced.
    struct ClipboardOutcome {
        /// Whether the pasteboard write was read back, or `nil` when the
        /// destination deliberately does not touch the pasteboard. The capture
        /// receipt reports a failed write as a failure rather than claiming a
        /// copy that never landed.
        var writeSucceeded: Bool?
    }

    /// Applies the destination's side-effects (clipboard write, shared state
    /// update). History recording is handled by the caller because it always
    /// happens regardless of destination.
    ///
    /// - Returns: whether the pasteboard write was verified, or `nil` when the
    ///   destination deliberately does not touch the pasteboard. The receipt
    ///   reports a failed write as a failure instead of claiming a copy.
    @discardableResult
    func applyDestinationSideEffects(
        text: String,
        destination: HardwareTriggerDestination,
        sharesCompletedTranscript: Bool? = nil
    ) async -> ClipboardOutcome {
        guard !text.isEmpty else { return ClipboardOutcome() }
        var clipboardWriteSucceeded: Bool?
        if let clipboardText = Self.clipboardTextAtStop(
            transcript: text,
            destination: destination
        ) {
            // The raw write happens exactly once, through the seam that owns
            // it (issue #1002/#1031). The read-back that follows only observes
            // the result, so the receipt reports a copy that landed rather
            // than one that was merely attempted (issue #945). Re-writing
            // after another app copied is the clipboard theft #1031 removed.
            polishClipboard.copyRaw(clipboardText)
            clipboardWriteSucceeded = await Self.clipboardHolds(clipboardText) { [polishClipboard] in
                polishClipboard.string
            }
        }

        // Keyboard handoffs keep their result solely in the nonce-scoped store.
        // Other destinations publish the completed transcript so the Live
        // Activity and foreground handoff can surface it.
        if let sharedTranscript = Self.legacySharedTranscript(
            text,
            sharesCompletedTranscript: sharesCompletedTranscript ?? sharesLiveTranscript
        ) {
            sharedState.lastCompletedTranscript = sharedTranscript
        }
        return ClipboardOutcome(writeSucceeded: clipboardWriteSucceeded)
    }

    /// A pasteboard write made from a background AppIntent can race process
    /// suspension, so the value may not be readable back immediately. Poll
    /// briefly before reporting the write as failed.
    ///
    /// - Returns: whether the value was read back. A `false` here is the only
    ///   thing that stops the receipt saying "Copied".
    static func clipboardHolds(_ text: String, read: () -> String?) async -> Bool {
        for attempt in 0..<3 {
            if read() == text { return true }
            await Task.yield()
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        return false
    }

    /// Raw text is usable immediately, including while polishing or without a key.
    static func clipboardTextAtStop(
        transcript: String,
        destination: HardwareTriggerDestination
    ) -> String? {
        guard !transcript.isEmpty else { return nil }
        switch destination {
        case .clipboard, .clipboardAndPostProcess:
            return transcript
        case .historyOnly:
            return nil
        case .auto:
            // `.auto` is mapped to a concrete destination by
            // `concreteDestination(for:)` before any side effect runs; treating
            // it as the clipboard here is a defensive default, never a path.
            return transcript
        }
    }

    /// Turns an `.auto` plan into the concrete destination the existing
    /// side-effect paths already understand (issue #1008). The keyboard lane
    /// skips the pasteboard because the words are going into the field the
    /// user was typing in; History still holds every capture either way.
    static func concreteDestination(
        for plan: AutoDestinationPolicy.Plan
    ) -> HardwareTriggerDestination {
        plan.writesClipboard ? .clipboard : .historyOnly
    }

    static func legacySharedTranscript(_ transcript: String, sharesCompletedTranscript: Bool) -> String? {
        sharesCompletedTranscript ? transcript : nil
    }
}
#endif
