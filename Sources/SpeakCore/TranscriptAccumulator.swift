import Foundation

/// Assembles a session's full transcript from the *segment* finals that
/// providers like Deepgram and ElevenLabs emit.
///
/// Providers disagree on what a "final" carries: some send only the newly
/// finalised words (a segment), others resend the whole utterance so far
/// (cumulative). This merges both shapes with one rule — a final that extends
/// what we already have replaces it, anything else is appended — so callers get
/// the same full transcript either way and nothing is doubled or dropped.
///
/// This is the single implementation of that rule: the shared clients use it to
/// honour the `FinalizingStreamingTranscriptionClient` full-transcript contract
/// and the iOS capture path uses it for its live display text, so the two can't
/// drift apart.
public struct TranscriptAccumulator: Sendable, Equatable {
    /// The full transcript so far. Empty until the first non-blank final.
    public private(set) var text: String = ""

    public init() {}

    public var isEmpty: Bool { self.text.isEmpty }

    /// The transcript, or `nil` when nothing has been finalised yet — the shape
    /// `finishAndWait()` returns.
    public var transcriptOrNil: String? { self.text.isEmpty ? nil : self.text }

    /// Merges one provider final into the transcript and returns the result.
    @discardableResult
    public mutating func append(final segment: String) -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.text }
        if self.text.isEmpty || trimmed == self.text || trimmed.hasPrefix(self.text + " ") {
            // Cumulative final (or the first one): it already contains
            // everything we had, so it replaces rather than appends.
            self.text = trimmed
        } else {
            self.text += " " + trimmed
        }
        return self.text
    }

    /// Adopts a transcript that is already known to be complete — e.g. the
    /// full-transcript return of `finishAndWait()`.
    public mutating func replace(with transcript: String) {
        self.text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func reset() {
        self.text = ""
    }

    /// The live display text: everything finalised plus a trailing interim.
    public func display(withInterim interim: String) -> String {
        let trimmed = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.text }
        return self.text.isEmpty ? trimmed : self.text + " " + trimmed
    }
}
