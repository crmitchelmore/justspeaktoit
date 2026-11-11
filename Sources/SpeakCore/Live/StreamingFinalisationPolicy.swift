import Foundation

/// Whether a stopping session must wait out the provider's bounded
/// finalisation, or can close the socket straight away.
///
/// Issue #641: for a provider whose finish does *not* flush buffered audio
/// (ElevenLabs), the rule used to be "close now unless an interim is still
/// unfinalised". A short utterance stopped before the provider's **first**
/// response has an empty interim and empty finals — indistinguishable, by that
/// rule, from a session with nothing outstanding — so the socket was closed on
/// audio that had been captured and sent but never transcribed, and the words
/// were lost. Audio the provider has not answered yet is exactly the case that
/// has to wait.
public enum StreamingFinalisationPolicy {
    /// - Parameters:
    ///   - finishFlushesBufferedAudio: the client's own contract flag — a finish
    ///     that flushes audio can always still produce words.
    ///   - hasUnfinalisedTranscript: an interim is displayed that no final has
    ///     committed yet.
    ///   - hasUnansweredAudio: audio was handed to the client that no response
    ///     has accounted for.
    public static func shouldAwaitFinalisation(
        finishFlushesBufferedAudio: Bool,
        hasUnfinalisedTranscript: Bool,
        hasUnansweredAudio: Bool
    ) -> Bool {
        finishFlushesBufferedAudio || hasUnfinalisedTranscript || hasUnansweredAudio
    }
}

/// Thread-safe "audio is outstanding" flag feeding
/// ``StreamingFinalisationPolicy``.
///
/// Set when PCM is handed to a streaming client (typically on a capture queue),
/// cleared when the provider answers (typically on the main actor). It is the
/// only evidence a stopping session has that words may still be owed to it, so
/// it carries its own lock rather than borrowing an actor's isolation.
public final class UnansweredAudioSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isOutstanding = false

    public init() {}

    public var isSet: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.isOutstanding
    }

    /// Audio has been handed to the client.
    public func record() {
        self.lock.lock()
        self.isOutstanding = true
        self.lock.unlock()
    }

    /// The provider has answered for everything sent so far.
    public func clear() {
        self.lock.lock()
        self.isOutstanding = false
        self.lock.unlock()
    }
}
