import Foundation

/// The phases of one lock-guarded live run. `idle` exists only before a
/// client's first `start()` and holds audio offered that early; later runs
/// begin at `connecting`.
enum LiveRunPhase { case idle, connecting, streaming, finishing, closed }

/// A run that owns its socket and the callers waiting for its finish.
protocol LiveFinishableRun: AnyObject {
    var phase: LiveRunPhase { get }
    var connection: (any StreamingWebSocketConnection)? { get set }
    /// What a finish caller receives: the run's confirmed text, or nil.
    var transcript: String? { get }
    var waiters: [CheckedContinuation<String?, Never>] { get set }
    /// Callers that joined while a failure was being published; they resume
    /// only after its error is out.
    var lateWaiters: [CheckedContinuation<String?, Never>] { get set }
    var deliveringFailure: Bool { get }
}

/// How lock-guarded clients whose run owns its socket and finish waiters
/// (Cartesia, Rev AI) attach a connection and join a finish. How a finish
/// drains, what an open handshake means, how frames arrive and how a run
/// retires stay with each client.
protocol LiveRunFinishing: AnyObject, Sendable {
    associatedtype FinishRun: LiveFinishableRun

    /// The active run. Read under the lock.
    var run: FinishRun { get }
    /// Runs `body` under the state lock, then performs the effects it recorded.
    func withState<Value>(_ body: (inout LiveDeferredEffects) -> Value) -> Value
    func isCurrent(_ active: FinishRun) -> Bool
    /// Caller holds the lock: detaches the run and releases its finish callers.
    func retire(_ active: FinishRun, _ effects: inout LiveDeferredEffects)
    /// Caller holds the lock: starts the provider's graceful finish.
    func beginFinish(_ active: FinishRun, _ effects: inout LiveDeferredEffects)
    func receive(_ active: FinishRun, _ connection: any StreamingWebSocketConnection)
    /// The transport reported the handshake on `active`'s socket.
    func connectionOpened(_ active: FinishRun)
    func log(_ event: String)
}

extension LiveRunFinishing {
    /// Joins the active run's finish. Concurrent callers share one outcome;
    /// cancelling the calling task aborts the session.
    func finishActiveRun() async -> String? {
        let active: FinishRun = withState { _ in run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                withState { effects in join(active, continuation, &effects) }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.withState { effects in if self.isCurrent(active) { self.retire(active, &effects) } }
        }
    }

    private func join(
        _ active: FinishRun, _ continuation: CheckedContinuation<String?, Never>,
        _ effects: inout LiveDeferredEffects
    ) {
        let transcript = active.transcript
        switch active.phase {
        case .connecting, .streaming, .finishing:
            guard !Task.isCancelled else {
                retire(active, &effects)
                effects.add { continuation.resume(returning: transcript) }
                return
            }
            active.waiters.append(continuation)
            beginFinish(active, &effects)
        case .idle:
            // Never started, so nothing was sent and nothing can be finished.
            retire(active, &effects)
            effects.add { continuation.resume(returning: transcript) }
        case .closed:
            // A failure still being published keeps late callers until its
            // error is out, exactly like callers that were already waiting.
            guard !active.deliveringFailure else {
                active.lateWaiters.append(continuation)
                return
            }
            effects.add { continuation.resume(returning: transcript) }
        }
    }

    /// Attaches `connection` to `active` and resumes it. Call outside the
    /// lock: the transport may call back synchronously. A run that already
    /// has a socket, or is no longer current, cancels `connection` instead.
    func attach(_ connection: any StreamingWebSocketConnection, to active: FinishRun) {
        let attached: Bool = withState { _ in
            guard isCurrent(active), active.connection == nil else { return false }
            active.connection = connection
            return true
        }
        guard attached else {
            connection.cancel()
            return
        }
        log("WebSocket connecting")
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.connectionOpened(active)
        }
        receive(active, connection)
    }
}
