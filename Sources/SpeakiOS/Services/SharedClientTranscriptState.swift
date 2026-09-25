#if os(iOS)
import Foundation
import SpeakCore

/// One recording's provider state, updated before callbacks hop to the UI actor.
/// Finishing reads this same state, so a queued UI callback cannot lose an error
/// or trailing draft. No audio buffers pass through this lock.
final class SharedClientTranscriptState: @unchecked Sendable {
    struct Snapshot: Sendable {
        let revision: UInt64
        let transcriptRevision: UInt64
        let text: String
        let confirmedText: String
        let isFinal: Bool
        let error: Error?
    }

    private let lock = NSLock()
    private var accumulator: TranscriptAccumulator
    private var text = ""
    private var isFinal = false
    private var error: Error?
    private var revision: UInt64 = 0
    private var transcriptRevision: UInt64 = 0
    private var closed = false

    init(shape: TranscriptFinalShape) { accumulator = TranscriptAccumulator(shape: shape) }

    var snapshot: Snapshot { lock.withLock { currentSnapshot } }

    func receive(_ value: String, isFinal: Bool) -> Snapshot? {
        lock.withLock {
            guard !closed else { return nil }
            if isFinal {
                accumulator.append(final: value)
                if error == nil || text.isEmpty { text = accumulator.text }
            } else {
                text = accumulator.display(withInterim: value)
            }
            self.isFinal = isFinal && error == nil
            revision += 1
            transcriptRevision = revision
            return currentSnapshot
        }
    }

    func fail(_ failure: Error) -> Snapshot? {
        lock.withLock {
            guard !closed, error == nil else { return nil }
            error = failure
            revision += 1
            return currentSnapshot
        }
    }

    func finish(whole: String?, cancelled: Bool) -> Snapshot {
        lock.withLock {
            guard !closed else { return currentSnapshot }
            if let whole, !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                accumulator.replace(with: whole)
                // A failed return contains confirmed words only. Keep the latest
                // visible draft without labelling it confirmed or guessing prefixes.
                if (error == nil && !cancelled) || text.isEmpty { text = accumulator.text }
                isFinal = error == nil && !cancelled
                revision += 1
                transcriptRevision = revision
            }
            closed = true
            return currentSnapshot
        }
    }

    func cancel() -> Snapshot {
        lock.withLock {
            closed = true
            return currentSnapshot
        }
    }

    private var currentSnapshot: Snapshot {
        Snapshot(revision: revision, transcriptRevision: transcriptRevision, text: text,
                 confirmedText: accumulator.text, isFinal: isFinal, error: error)
    }
}
#endif
