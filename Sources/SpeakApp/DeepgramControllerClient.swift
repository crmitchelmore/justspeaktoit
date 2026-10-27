import Foundation
import SpeakCore

/// One recording's Mac adapter. Core owns PCM ordering, CloseStream and the
/// bounded trailing-response drain; capture and result metadata stay in Mac.
final class DeepgramControllerClient: @unchecked Sendable {
    struct Snapshot: Sendable {
        let text: String
        let confirmedText: String
        let error: Error?
    }

    private let client: any FinalizingStreamingTranscriptionClient
    private let lock = NSLock()
    private var committed = TranscriptAccumulator(shape: .standaloneSegments)
    private var interim = ""
    private var failure: Error?
    private var reportedFailure = false
    private var started = false
    private var closed = false
    private var finished: Snapshot?
    private var finishing: Task<Snapshot, Never>?
    private var finishCallers = 0

    init(client: any FinalizingStreamingTranscriptionClient) { self.client = client }

    var snapshot: Snapshot { lock.withLock { value } }
    var pendingFinishes: Int { lock.withLock { finishCallers } }

    private var value: Snapshot {
        finished ?? Snapshot(
            text: committed.display(withInterim: interim), confirmedText: committed.text, error: failure
        )
    }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let begin = lock.withLock { () -> Bool in
            guard !started, !closed else { return false }
            started = true
            return true
        }
        guard begin else { return }
        client.start(onTranscript: { [weak self] text, final in
            guard let self else { return }
            let deliver = self.lock.withLock { () -> Bool in
                guard !self.closed else { return false }
                if final {
                    self.committed.append(final: text)
                    self.interim = ""
                } else {
                    self.interim = text
                }
                return true
            }
            if deliver { onTranscript(text, final) }
        }, onError: { [weak self] error in
            guard let self else { return }
            let deliver = self.lock.withLock { () -> Bool in
                guard !self.closed, self.failure == nil else { return false }
                self.failure = error
                return true
            }
            if deliver { onError(error) }
        })
        // stop() can win after admission but before the underlying start.
        // Deepgram.start creates a fresh Core run, so retire that connection.
        if lock.withLock({ closed }) { client.stop() }
    }

    func sendAudio(_ audio: Data) {
        guard !lock.withLock({ closed }) else { return }
        client.sendAudio(audio)
    }

    func finishAndWait() async -> Snapshot {
        if let finished = lock.withLock({ finished }) { return finished }
        lock.withLock { finishCallers += 1 }
        defer { lock.withLock { finishCallers -= 1 } }
        return await withTaskCancellationHandler {
            let owned = lock.withLock { () -> Task<Snapshot, Never> in
                if let finishing { return finishing }
                // Record a caller's cancellation before stopping Core. A
                // directly cancelled Core waiter could wake another caller
                // before the adapter recorded their shared error outcome.
                let task = Task.detached(priority: Task.currentPriority) { [self] in
                    let whole = await client.finishAndWait()
                    return finish(whole: whole)
                }
                finishing = task
                return task
            }
            return await owned.value
        } onCancel: { [weak self] in self?.stop() }
    }

    private func finish(whole: String?) -> Snapshot {
        lock.withLock {
            if let finished { return finished }
            if let whole = whole?.trimmingCharacters(in: .whitespacesAndNewlines), !whole.isEmpty {
                let previousConfirmed = committed.text
                committed.replace(with: whole)
                // Metadata can end a healthy stream without confirming the
                // last visible draft. Preserve that draft when the confirmed
                // session did not change; a genuinely updated whole result is
                // authoritative on success. Never deduplicate spoken turns.
                if failure == nil, whole != previousConfirmed { interim = "" }
            }
            let result = Snapshot(
                // A trailing final may arrive only through the whole result,
                // even when CloseStream subsequently fails. Rebuild from those
                // updated confirmed words and retain the unconfirmed draft on
                // failure; never replace newer server text with an old display.
                text: committed.display(withInterim: interim),
                confirmedText: committed.text, error: failure
            )
            closed = true
            finished = result
            return result
        }
    }

    func takeFailureForReporting() -> Error? {
        lock.withLock {
            guard !reportedFailure, let failure else { return nil }
            reportedFailure = true
            return failure
        }
    }

    func stop() {
        lock.withLock {
            if !closed, failure == nil { failure = CancellationError() }
            closed = true
        }
        client.stop()
    }
}
