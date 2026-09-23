import Foundation
import SpeakCore

/// Capture a run's text and failure before asynchronous MainActor delivery.
/// Each start owns one instance; queued callbacks cannot mutate its replacement.
final class ElevenLabsControllerRun: @unchecked Sendable {
    struct Snapshot {
        let text: String
        let confirmedText: String
        let error: Error?
    }

    private let lock = NSLock()
    private var committed = TranscriptAccumulator(shape: .standaloneSegments)
    private var interim = ""
    private var retainedDisplay: String?
    private var failure: Error?
    private var failureReported = false
    private var closed = false

    var snapshot: Snapshot { lock.withLock { value } }

    private var value: Snapshot {
        Snapshot(
            text: retainedDisplay ?? committed.display(withInterim: interim),
            confirmedText: committed.text, error: failure
        )
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
            let visible = value.text
            if let whole = whole?.trimmingCharacters(in: .whitespacesAndNewlines), !whole.isEmpty {
                committed.replace(with: whole)
                if failure == nil {
                    interim = ""
                }
            }
            // Failure/cancellation can return a confirmed prefix or a revised
            // confirmed segment. Retain the visible draft separately, without
            // mislabelling it as confirmed or dropping it on a nonempty return.
            if failure != nil { retainedDisplay = visible.isEmpty ? committed.text : visible }
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

    func cancel() {
        lock.withLock {
            if !closed, failure == nil { failure = CancellationError() }
            closed = true
        }
    }
}
