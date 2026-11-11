import Foundation

/// Decides whether a capture that failed to start is something the user has to
/// be told about — and, on the presentation side, whether a published failure
/// is new enough to alert on.
///
/// This exists because a Home Screen quick action has no UI of its own: when
/// the start throws, the only thing that happens today is a log line, so the
/// press looks like it worked and no recording ever begins (issue #944). The
/// fix is not a cheerful message but a truthful one, which means being equally
/// careful about the failures that must *not* alert: a start the user cancelled
/// by pressing again, a run a newer capture superseded, and a refusal whose
/// owning surface is already on screen.
///
/// Kept pure and in SpeakCore so the whole decision is covered by host tests
/// rather than only by a simulator run.
public enum CaptureStartFailurePolicy {
    /// A start failure reduced to the text the policy chose to present.
    ///
    /// The thrown error is kept for the log, but what reaches the alert has to
    /// be the message the policy settled on — trimmed, and replaced by the
    /// fallback when the error had nothing quotable to say. Publishing the
    /// original instead is how a blank or whitespace-only `localizedDescription`
    /// reaches the user as an empty alert.
    public struct PresentedFailure: LocalizedError, Equatable, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var errorDescription: String? { self.message }
    }

    /// Why a failed start is not shown to the user. Logged, never presented.
    public enum SilentReason: String, Equatable, Sendable {
        /// The start was cancelled — a stop, or a second quick-action press
        /// while start-up was still in flight. Cancelling is the user getting
        /// what they asked for, not a failure.
        case cancelled
        /// A newer capture is already in flight, so this run has been retired.
        /// Alerting would attach an old failure to a session that is running.
        case superseded
        /// The in-app recorder owns the microphone. That surface is on screen
        /// showing the recording it is running (#1043 owns that ownership
        /// rule), so a second alert would only contradict it.
        case ownedByAnotherSurface
    }

    /// What to do about a capture start that produced no recording.
    public enum Disposition: Equatable, Sendable {
        /// Terminal: nothing is recording, and no other surface has said why.
        /// The associated value is the message to present.
        case surface(String)
        /// Cancelled, superseded or already owned elsewhere. Log it and stop.
        case logOnly(SilentReason)

        /// The message to present, or `nil` when this failure stays silent.
        public var presentedMessage: String? {
            guard case .surface(let message) = self else { return nil }
            return message
        }
    }

    /// Classifies a start that did not result in a recording.
    ///
    /// - Parameters:
    ///   - errorDescription: the thrown error's user-facing text, or `nil` when
    ///     the start refused without throwing.
    ///   - isCancellation: the thrown error was a `CancellationError`. The
    ///     recorder's run-identity guard already turns a retired start into
    ///     one, so this reads that existing signal rather than adding a second
    ///     guard of its own.
    ///   - laterCaptureInFlight: a capture is active *now*, after this start
    ///     failed — so a newer run replaced this one.
    ///   - microphoneOwnedElsewhere: the in-app recorder holds the microphone.
    public static func disposition(
        errorDescription: String?,
        isCancellation: Bool,
        laterCaptureInFlight: Bool,
        microphoneOwnedElsewhere: Bool
    ) -> Disposition {
        if isCancellation { return .logOnly(.cancelled) }
        if laterCaptureInFlight { return .logOnly(.superseded) }
        if microphoneOwnedElsewhere { return .logOnly(.ownedByAnotherSurface) }
        let message = errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !message.isEmpty else {
            // A refusal with nothing quotable still has to say something true:
            // the recording did not start.
            return .surface(CaptureLinkFailure.recordingFailed.localizedDescription)
        }
        return .surface(message)
    }

    /// Whether a published session failure is new to the surface presenting it.
    ///
    /// The alert is driven both by a change notification and by a read taken
    /// when the view attaches — the second is what covers a cold launch, where
    /// a quick action can fail before any observer exists. Both routes go
    /// through here so one failure cannot raise two alerts.
    ///
    /// The identity is the *publication*, not its text. Two refusals can carry
    /// the same words — a second capture link refused for the same reason after
    /// the first alert was dismissed is the obvious case — and de-duplicating on
    /// the message would swallow the later one, with no `nil` in between to
    /// re-arm anything. A token that changes on every publication cannot.
    public static func shouldPresent(token: UUID?, lastPresented: UUID?) -> Bool {
        guard let token else { return false }
        return token != lastPresented
    }
}
