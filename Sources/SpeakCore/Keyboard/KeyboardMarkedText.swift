import Foundation

/// Streaming a dictation into the host's text field as *marked* (provisional,
/// underlined) text, the way Apple dictation and CJK input methods do, and —
/// far more importantly — guaranteeing that provisional text is never left
/// behind (issue #1004).
///
/// Marked text is not the keyboard's to keep. It sits in the user's document
/// looking like text they typed, and only the keyboard can resolve it. So
/// every path out of a run has to end in exactly one of two proxy calls:
///
/// * **finalise** — `setMarkedText(final)` then `unmarkText()`, which commits
///   the words. This is the only success ending.
/// * **clear** — `setMarkedText("")` then `unmarkText()`, which commits an
///   empty string and so removes the provisional text.
///
/// `KeyboardMarkedTextSession` is a pure value type that decides which, and
/// makes both idempotent: once a run has ended, every later question answers
/// `.none`, so a double dismissal or a cancel-then-deactivate cannot double
/// up. The keyboard extension is a thin `switch` over `Action`, which is what
/// lets the abandonment paths be proved on the host with `swift test` rather
/// than argued about.
///
/// Two rules are absolute and are encoded in `init`:
/// * A **secure field is never marked into.** Streaming a password back into
///   the field as visible provisional text would be a disclosure, so a session
///   created for a secure field starts disabled and stays that way.
/// * Streaming is **abandoned, never resumed**, once the ground moves. A
///   changed `documentIdentifier` or a caret move the keyboard did not cause
///   means the marked range can no longer be reasoned about, so the session
///   clears what it put there and degrades to plain insertion for the rest of
///   the run. Falling back loses the live preview; guessing would corrupt the
///   user's document.
public struct KeyboardMarkedTextSession: Equatable, Sendable {
    /// What the extension should do to `UITextDocumentProxy`.
    public enum Action: Equatable, Sendable {
        /// Nothing to do.
        case none
        /// `setMarkedText(text, selectedRange:)` with the caret at the end.
        case mark(String)
        /// `setMarkedText(text, …)` then `unmarkText()`: commit these words.
        case finalise(String)
        /// `setMarkedText("", …)` then `unmarkText()`: take the provisional
        /// text back out of the field.
        case clear
    }

    /// The provisional text currently in the user's field, or `nil` when the
    /// field holds nothing of ours.
    public private(set) var outstanding: String?
    /// Whether this run may still stream. Once false it never becomes true
    /// again: the run finishes by plain insertion instead.
    public private(set) var isStreaming: Bool

    /// - Parameters:
    ///   - streamsMarkedText: the user's preference. Off means the run behaves
    ///     exactly as it did before this feature existed.
    ///   - isSecureField: a secure field is never streamed into, whatever the
    ///     preference says.
    public init(streamsMarkedText: Bool, isSecureField: Bool) {
        self.outstanding = nil
        self.isStreaming = streamsMarkedText && !isSecureField
    }

    /// A new interim transcript arrived from the app.
    ///
    /// An empty interim never clears text already shown: providers routinely
    /// emit an empty hypothesis mid-utterance, and blanking the field on every
    /// one of those would flicker. The words leave the field only through
    /// `finish` or one of the abandonment paths.
    public mutating func interim(_ text: String) -> Action {
        guard isStreaming else { return .none }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != outstanding else { return .none }
        outstanding = trimmed
        return .mark(trimmed)
    }

    /// The final transcript is ready.
    ///
    /// Returns `.finalise` only when this session actually has provisional
    /// text in the field; otherwise `.none`, which tells the caller to insert
    /// the transcript the ordinary way. Either way the session is finished,
    /// so a repeat — a second poll tick landing on the same completed record —
    /// does nothing.
    public mutating func finish(_ transcript: String) -> Action {
        isStreaming = false
        guard outstanding != nil else { return .none }
        outstanding = nil
        return .finalise(transcript)
    }

    /// The run ended without a transcript to commit: cancelled, failed, timed
    /// out, the keyboard was dismissed, or the target changed. Idempotent.
    public mutating func abandon() -> Action {
        isStreaming = false
        guard outstanding != nil else { return .none }
        outstanding = nil
        return .clear
    }

    /// The keyboard moved to a different text document.
    ///
    /// Returns `.none` — deliberately, and this is the one abandonment path
    /// that issues no proxy call at all. By the time the extension learns the
    /// document changed, `textDocumentProxy` already addresses the **new**
    /// field, so a `.clear` here would run `setMarkedText("")` and
    /// `unmarkText()` against a document this session never wrote to: at best
    /// a no-op, at worst it erases or force-commits the user's own in-progress
    /// composition in the field they just moved to. The old provisional range
    /// is unreachable from here either way — the host resolves it when the
    /// field resigns first responder — so the correct action is to forget the
    /// ledger and stop streaming, not to reach through the wrong proxy.
    public mutating func documentChanged() -> Action {
        isStreaming = false
        outstanding = nil
        return .none
    }

    /// The caret moved for a reason the keyboard did not cause. UIKit's own
    /// handling of marked text across a selection change is host-defined, so
    /// the session stops trusting its ledger, takes its text back, and lets
    /// the run finish by plain insertion — which is exactly what #1030
    /// guarantees still arrives.
    public mutating func caretMoved() -> Action {
        abandon()
    }
}
