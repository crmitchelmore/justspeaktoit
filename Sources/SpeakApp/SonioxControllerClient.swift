import Foundation
import SpeakCore

/// The macOS Soniox adapter: capture stays in SonioxLiveController; all
/// transport, pre-roll, request and finalisation semantics are shared.
/// One adapter belongs to one recording and is never restarted.
final class SonioxControllerClient: @unchecked Sendable {
    /// Keep the former 1.5 s send + 2 s final-response budget without the
    /// legacy unconditional wait. User-selected grace remains in the controller.
    static let finishTimeout: TimeInterval = 3.5
    static let preferredChunkBytes = 3_200
    static let minimumChunkBytes = 1_600

    struct Snapshot: Sendable {
        let text: String
        let confirmedText: String
        let error: Error?
    }

    private let client: any FinalizingStreamingTranscriptionClient
    private let lock = NSLock()
    private var accumulator: TranscriptAccumulator
    private var text = ""
    private var error: Error?
    private var started = false
    private var closed = false
    private var finalized = false

    convenience init(apiKey: String, model: String, language: String?, sampleRate: Int = 16_000) {
        self.init(client: SonioxLiveClient(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            finishTimeout: Self.finishTimeout
        ))
    }

    init(client: any FinalizingStreamingTranscriptionClient) {
        self.client = client
        self.accumulator = TranscriptAccumulator(shape: client.finalShape)
    }

    var snapshot: Snapshot {
        lock.withLock { Snapshot(text: text, confirmedText: accumulator.text, error: error) }
    }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let begin = lock.withLock { () -> Bool in
            guard !started, !closed else { return false }
            started = true
            return true
        }
        guard begin else { return }
        client.start(onTranscript: { [weak self] value, isFinal in
            guard let self else { return }
            let display = self.lock.withLock { () -> String? in
                guard !self.closed else { return nil }
                if isFinal { self.accumulator.append(final: value) }
                self.text = isFinal ? self.accumulator.text : self.accumulator.display(withInterim: value)
                return self.text
            }
            if let display { onTranscript(display, isFinal) }
        }, onError: { [weak self] error in
            guard let self else { return }
            let report = self.lock.withLock { () -> Bool in
                guard !self.closed, self.error == nil else { return false }
                self.error = error
                return true
            }
            if report { onError(error) }
        })
    }

    /// Synchronous bounded admission; no task or extra audio queue per chunk.
    func sendAudio(_ data: Data) {
        guard !lock.withLock({ closed }) else { return }
        client.sendAudio(data)
    }

    func finishAndWait() async -> Snapshot {
        let whole = await client.finishAndWait()
        let taskWasCancelled = Task.isCancelled
        return lock.withLock {
            if !finalized, let whole, !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                accumulator.replace(with: whole)
                // Failure/cancellation can return only confirmed words while
                // the visible draft contains speech not yet confirmed. Keep
                // that display and the confirmed result separately; neither
                // prefixes nor lengths can safely merge provider revisions.
                if (error == nil && !closed && !taskWasCancelled) || text.isEmpty {
                    text = accumulator.text
                }
            }
            // A nil result does not erase a draft or previously confirmed text.
            closed = true
            finalized = true
            return Snapshot(text: text, confirmedText: accumulator.text, error: error)
        }
    }

    func cancel() {
        lock.withLock { closed = true }
        client.cancel()
    }
}
