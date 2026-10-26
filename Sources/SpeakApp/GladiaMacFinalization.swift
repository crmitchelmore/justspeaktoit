import Foundation

/// One recording's rich result and terminal wait. Finals are recorded before
/// queued UI delivery, so end_session cannot outrun the last confidence/turn.
final class GladiaMacFinalization: @unchecked Sendable {
    struct Snapshot {
        let finals: [GladiaTranscriptEvent]
        let interim: GladiaTranscriptEvent?
        let error: Error?
    }

    let onTranscript: (GladiaTranscriptEvent) -> Void
    let onError: (Error) -> Void
    let pendingSendGroup = DispatchGroup()
    private let lock = NSLock()
    private var finals: [GladiaTranscriptEvent] = []
    private var interim: GladiaTranscriptEvent?
    private var failure: Error?
    private var failureReported = false
    private var closed = false
    private var finishing = false
    private var stopClaimed = false
    private var stopSent = false
    private var reportingFailure = false
    private var waiters: [CheckedContinuation<Snapshot, Never>] = []

    init(
        onTranscript: @escaping (GladiaTranscriptEvent) -> Void = { _ in },
        onError: @escaping (Error) -> Void = { _ in }
    ) {
        self.onTranscript = onTranscript
        self.onError = onError
    }

    var snapshot: Snapshot { lock.withLock { value } }
    private var value: Snapshot { Snapshot(finals: finals, interim: interim, error: failure) }
    var acceptsAudio: Bool { lock.withLock { !finishing && !closed } }
    var isFinishing: Bool { lock.withLock { finishing && !closed } }

    func record(_ event: GladiaTranscriptEvent) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if event.isFinal { finals.append(event); interim = nil } else { interim = event }
            return true
        }
    }

    func takeFailureForReporting() -> Error? {
        lock.withLock {
            guard !failureReported, let failure else { return nil }
            failureReported = true
            return failure
        }
    }

    func claimStop() -> Bool {
        lock.withLock {
            guard finishing, !closed, !stopClaimed else { return false }
            stopClaimed = true
            return true
        }
    }

    /// Revalidate the claimed stop immediately before invoking the socket.
    func handOffStop() -> Bool {
        lock.withLock {
            guard finishing, !closed, stopClaimed, !stopSent else { return false }
            stopSent = true
            return true
        }
    }

    func wait(
        timeout: TimeInterval,
        schedule: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void,
        registered: () -> Void,
        begin: () -> Void
    ) async -> Snapshot {
        await withCheckedContinuation { continuation in
            let registration = lock.withLock { () -> (Snapshot?, Bool) in
                if reportingFailure { waiters.append(continuation); return (nil, false) }
                guard !closed else { return (value, false) }
                waiters.append(continuation)
                guard !finishing else { return (nil, false) }
                finishing = true
                return (nil, true)
            }
            registered()
            if let snapshot = registration.0 { continuation.resume(returning: snapshot) }
            guard registration.1 else { return }
            schedule(max(0, timeout)) { [weak self] in
                guard let self else { return }
                let error = GladiaMacFinalizationTimeout()
                self.complete(error: error, beforeResume: { self.onError(error) })
            }
            // Install every waiter before a synchronous stop/end response.
            begin()
        }
    }

    func ended() {
        let expected = lock.withLock { finishing && stopSent }
        complete(
            error: expected ? nil : GladiaLiveError.connectionFailed,
            beforeResume: expected ? nil : { self.onError(GladiaLiveError.connectionFailed) }
        )
    }

    func complete(error: Error?, beforeResume: (() -> Void)? = nil) {
        let terminal = lock.withLock { () -> Snapshot? in
            guard !closed else { return nil }
            failure = error
            closed = true
            reportingFailure = beforeResume != nil
            return value
        }
        guard let terminal else { return }
        // A concurrent finish joining this closed run remains parked until
        // its error callback returns, just like the original finish callers.
        beforeResume?()
        let pending = lock.withLock { () -> [CheckedContinuation<Snapshot, Never>] in
            reportingFailure = false
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: terminal) }
    }

}

private struct GladiaMacFinalizationTimeout: LocalizedError {
    var errorDescription: String? {
        "Gladia did not finish the live session within the finalization budget. Recorded text was retained."
    }
}

/// Existing URLSession transport, with only the socket boundary injectable for
/// protocol/lifecycle fixtures. No endpoint or session policy is introduced.
protocol GladiaMacWebSocket: AnyObject, Sendable {
    var state: URLSessionTask.State { get }
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: GladiaMacWebSocket {}
