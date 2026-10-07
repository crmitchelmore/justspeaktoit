import Foundation
import SpeakCore

/// Provider callbacks update one recording's state before any MainActor hop.
/// Capture and PCM processing never take this lock.
final class SharedClientControllerRun: @unchecked Sendable {
    struct Snapshot: Sendable {
        let revision: UInt64
        let transcriptRevision: UInt64
        let text: String
        let confirmedText: String
        let isFinal: Bool
        let confidence: Double?
        let error: Error?
    }

    let modelIdentifier: String
    /// The client reports utterance boundaries itself, so none is inferred
    /// from a final.
    let hasExplicitBoundaries: Bool
    private let lock = NSLock()
    private var accumulator: TranscriptAccumulator
    private var text = ""
    private var isFinal = false
    private var confidence: Double?
    private var error: Error?
    private var reportedError = false
    private var revision: UInt64 = 0
    private var transcriptRevision: UInt64 = 0
    private var closed = false

    init(shape: TranscriptFinalShape, modelIdentifier: String, hasExplicitBoundaries: Bool = false) {
        accumulator = TranscriptAccumulator(shape: shape)
        self.modelIdentifier = modelIdentifier
        self.hasExplicitBoundaries = hasExplicitBoundaries
    }

    var snapshot: Snapshot { lock.withLock { current } }

    /// Whether this recording still accepts provider events.
    var isOpen: Bool { lock.withLock { !closed } }

    /// Folds one provider update. A client's authoritative `projection`
    /// replaces the folded text instead of being appended to it.
    func receive(_ text: String, isFinal: Bool, projection: StreamingTranscriptSnapshot? = nil) -> Snapshot? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let authoritative = projection?.resolvedDisplayText != nil
        guard !value.isEmpty || authoritative else { return nil }
        return lock.withLock {
            guard !closed else { return nil }
            if authoritative {
                let display = SharedTranscriptProjection.apply(
                    eventText: value, isFinal: isFinal, snapshot: projection, accumulator: &accumulator
                ) ?? accumulator.text
                if error == nil || self.text.isEmpty { self.text = display }
            } else if isFinal {
                accumulator.append(final: value)
                if error == nil || self.text.isEmpty { self.text = accumulator.text }
            } else {
                self.text = accumulator.display(withInterim: value)
            }
            self.isFinal = isFinal && error == nil
            confidence = projection?.latestUpdateConfidence
            revision += 1
            transcriptRevision = revision
            return current
        }
    }

    func fail(_ failure: Error) -> Snapshot? {
        lock.withLock {
            guard !closed, error == nil else { return nil }
            error = failure
            revision += 1
            return current
        }
    }

    /// Adopts the finish result. A healthy finish then takes the client's
    /// final `projection`, when it has one, as the whole session's text.
    func finish(whole: String?, cancelled: Bool, projection: StreamingTranscriptSnapshot? = nil) -> Snapshot {
        lock.withLock {
            let previousText = text
            let previousFinal = isFinal
            if cancelled, error == nil { error = CancellationError() }
            if let whole, !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                accumulator.replace(with: whole)
                // A failed/cancelled return can contain only confirmed text.
                // Keep the existing draft separately without prefix/length guesses.
                if (error == nil && !closed) || text.isEmpty { text = accumulator.text }
                isFinal = error == nil && !closed
            }
            if error == nil, !closed, let projection,
               let resolved = projection.resolvedDisplayText?.trimmingCharacters(in: .whitespacesAndNewlines),
               projection.confirmedText != nil || !resolved.isEmpty {
                accumulator.replace(with: resolved)
                text = resolved
                isFinal = true
            }
            revision += 1
            if text != previousText || isFinal != previousFinal { transcriptRevision = revision }
            closed = true
            return current
        }
    }

    func takeFailure() -> Error? {
        lock.withLock {
            guard !reportedError, let error else { return nil }
            reportedError = true
            return error
        }
    }

    @discardableResult
    func cancel() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if error == nil { error = CancellationError() }
            closed = true
            return true
        }
    }

    private var current: Snapshot {
        Snapshot(
            revision: revision, transcriptRevision: transcriptRevision, text: text,
            confirmedText: accumulator.text, isFinal: isFinal, confidence: confidence, error: error
        )
    }
}
