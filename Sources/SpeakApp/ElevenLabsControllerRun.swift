import Foundation
import SpeakCore

/// Capture a run's text and failure before asynchronous MainActor delivery.
/// Each start owns one instance; queued callbacks cannot mutate its replacement.
final class ElevenLabsControllerRun: @unchecked Sendable {
    struct Snapshot {
        let text: String
        let error: Error?
    }

    private let lock = NSLock()
    private var committed = TranscriptAccumulator(shape: .standaloneSegments)
    private var interim = ""
    private var failure: Error?
    private var failureReported = false
    private var closed = false

    var snapshot: Snapshot { lock.withLock { value } }

    private var value: Snapshot {
        Snapshot(text: committed.display(withInterim: interim), error: failure)
    }

    func record(text: String, final: Bool) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if final {
                committed.append(final: text)
                interim = ""
            } else {
                interim = text
            }
            return true
        }
    }

    func record(error: Error) -> Bool {
        lock.withLock {
            guard !closed, failure == nil else { return false }
            failure = error
            return true
        }
    }

    func finish(whole: String?) -> Snapshot {
        lock.withLock {
            if let whole = whole?.trimmingCharacters(in: .whitespacesAndNewlines), !whole.isEmpty {
                // A failed shared finish can return only previously confirmed
                // words. Keep the newer draft instead of discarding it then.
                if failure == nil || whole != committed.text {
                    committed.replace(with: whole)
                    interim = ""
                }
            }
            closed = true
            return value
        }
    }

    func takeFailureForReporting() -> Error? {
        lock.withLock {
            guard !failureReported, let failure else { return nil }
            failureReported = true
            return failure
        }
    }

    func close() { lock.withLock { closed = true } }
}
