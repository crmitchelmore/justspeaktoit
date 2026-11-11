import Foundation

/// The serial queue that confines one live client's run state. `sync` is
/// re-entrant: a caller already on the queue runs inline, so lifecycle code
/// and synchronous transport callbacks can re-enter the client without
/// deadlocking.
final class LiveClientStateQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Bool>()

    init(label: String) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: key, value: true)
    }

    func sync<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: key) == true { return action() }
        return queue.sync(execute: action)
    }
}

/// The confinement mechanics shared by live clients whose runs live on a
/// `LiveClientStateQueue`: queue access, run-scoped deadlines and the
/// `finishAndWait()` wait/cancel scaffolding. It owns no protocol codec and
/// no terminal semantics: each client still decides what ends its stream, when
/// a finish succeeds or fails and what a waiter is resumed with.
protocol QueueConfinedLiveClient: AnyObject, Sendable {
    associatedtype LiveRun: AnyObject, Sendable

    var stateQueue: LiveClientStateQueue { get }
    var schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void { get }
    /// The current run. Read only on the state queue.
    var run: LiveRun { get }
    /// `active` is still the current run and has not closed.
    func isCurrent(_ active: LiveRun) -> Bool
    /// Ends `active` at once, resuming its finish waiters with what it has.
    func close(_ active: LiveRun)
}

extension QueueConfinedLiveClient {
    func synchronized<Value>(_ action: () -> Value) -> Value { stateQueue.sync(action) }

    /// Runs `action` on the state queue after `seconds`, only while `active`
    /// is still current, so a deadline can never touch a retired run.
    func after(_ seconds: TimeInterval, _ active: LiveRun, action: @escaping @Sendable (Self, LiveRun) -> Void) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    /// The `finishAndWait()` scaffolding. On the state queue, a run that is no
    /// longer current or cannot finish is closed (when it is still this
    /// client's run) and answered with its text at once, as is a caller whose
    /// task is already cancelled. Otherwise `register` adds the waiter and
    /// begins the provider's own finish, which alone decides when and with
    /// what the waiter resumes. Cancelling the waiting task closes the run if
    /// it is still current.
    func awaitFinish(
        canFinish: (LiveRun) -> Bool,
        transcript: (LiveRun) -> String?,
        register: (LiveRun, CheckedContinuation<String?, Never>) -> Void
    ) async -> String? {
        let active = synchronized { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    guard isCurrent(active), canFinish(active) else {
                        if active === run { close(active) }
                        continuation.resume(returning: transcript(active))
                        return
                    }
                    if Task.isCancelled {
                        close(active)
                        continuation.resume(returning: transcript(active))
                        return
                    }
                    register(active, continuation)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }
}
