import Foundation

/// How a streaming provider shapes the *final* transcripts it emits.
///
/// Text alone cannot distinguish a provider retry from two semantically
/// identical utterances ("Yes." followed by "Yes."), so the shape is declared
/// per client instead of inferred from equality or prefixes (issue #700).
public enum TranscriptFinalShape: Sendable, Equatable {
    /// Every final is a newly finalised segment that has not been delivered
    /// before. Identical consecutive text is a genuine repeat and must append;
    /// duplicates are dropped only by explicit provider event identity.
    case standaloneSegments

    /// Every final restates the transcript so far, so each one replaces the
    /// previous — including revisions that are not strict prefix extensions
    /// (punctuation, casing or word corrections).
    case cumulativeTranscript
}

/// Assembles a session's full transcript from the finals a provider emits.
///
/// The provider's declared `TranscriptFinalShape` decides the fold: standalone
/// segments append (even when their text repeats), cumulative transcripts
/// replace (even when the revision is not a prefix extension). This is the
/// single implementation of that rule: the shared clients use it to honour the
/// `FinalizingStreamingTranscriptionClient` full-transcript contract and both
/// platform capture paths use it for their live display text, so the
/// consumers cannot drift apart.
public struct TranscriptAccumulator: Sendable, Equatable {
    /// How finals folded by this accumulator are shaped.
    public let shape: TranscriptFinalShape

    /// The full transcript so far. Empty until the first non-blank final.
    public private(set) var text: String = ""

    /// Provider event identities already folded, used to drop retransmissions
    /// of the same event. Only populated when callers supply identities.
    private var seenEventIDs: Set<String> = []

    public init(shape: TranscriptFinalShape) {
        self.shape = shape
    }

    public var isEmpty: Bool { self.text.isEmpty }

    /// The transcript, or `nil` when nothing has been finalised yet — the shape
    /// `finishAndWait()` returns.
    public var transcriptOrNil: String? { self.text.isEmpty ? nil : self.text }

    /// Merges one provider final into the transcript and returns the result.
    ///
    /// - Parameters:
    ///   - segment: the final's text. Blank finals are ignored.
    ///   - eventID: a stable provider event/sequence identity, when the
    ///     provider has one. A repeated identity is a retransmission and is
    ///     dropped; without an identity every distinct final event is folded,
    ///     including ones whose text matches what was already accumulated.
    @discardableResult
    public mutating func append(final segment: String, eventID: String? = nil) -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.text }
        if let eventID {
            guard self.seenEventIDs.insert(eventID).inserted else { return self.text }
        }
        switch self.shape {
        case .standaloneSegments:
            self.text = self.text.isEmpty ? trimmed : self.text + " " + trimmed
        case .cumulativeTranscript:
            self.text = trimmed
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
        self.seenEventIDs = []
    }

    /// The live display text for an interim update.
    ///
    /// Standalone interims extend what is finalised; cumulative interims
    /// already restate the whole transcript so far and stand alone.
    public func display(withInterim interim: String) -> String {
        let trimmed = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.text }
        switch self.shape {
        case .standaloneSegments:
            return self.text.isEmpty ? trimmed : self.text + " " + trimmed
        case .cumulativeTranscript:
            return trimmed
        }
    }
}
