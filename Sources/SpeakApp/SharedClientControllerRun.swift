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
        let error: Error?
    }

    let modelIdentifier: String
    private let lock = NSLock()
    private var accumulator: TranscriptAccumulator
    private var text = ""
    private var isFinal = false
    private var error: Error?
    private var reportedError = false
    private var revision: UInt64 = 0
    private var transcriptRevision: UInt64 = 0
    private var closed = false

    init(shape: TranscriptFinalShape, modelIdentifier: String) {
        accumulator = TranscriptAccumulator(shape: shape)
        self.modelIdentifier = modelIdentifier
    }

    var snapshot: Snapshot { lock.withLock { current } }

    func receive(_ text: String, isFinal: Bool) -> Snapshot? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return lock.withLock {
            guard !closed else { return nil }
            if isFinal {
                accumulator.append(final: value)
                if error == nil || self.text.isEmpty { self.text = accumulator.text }
            } else {
                self.text = accumulator.display(withInterim: value)
            }
            self.isFinal = isFinal && error == nil
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

    func finish(whole: String?, cancelled: Bool) -> Snapshot {
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
            confirmedText: accumulator.text, isFinal: isFinal, error: error
        )
    }
}
