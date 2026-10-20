import Foundation

/// Bounds how long an automation client waits, without abandoning the command it
/// is waiting on.
///
/// Separate from `AutomationRequestCoordinator` because the two answer different
/// questions: the coordinator owns the idempotency caches, this owns the race
/// between a running command and the caller's patience. Shared by every local
/// transport (the macOS UNIX socket and the Windows named pipe).
enum AutomationDeadline {
    /// Coordinator runs publish once to removable waiters. A timed-out retry
    /// must not leave another observer task awaiting an uncooperative command.
    static func value(
        of completion: AutomationCompletion, within seconds: TimeInterval,
        id: String, command: AutomationCommand
    ) async -> AutomationResponse {
        let gate = Gate()
        let observation = UUID()
        let outcome: AutomationResponse? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                completion.observe(observation) { gate.settle($0) }
                let timer = Task.detached {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    completion.remove(observation)
                    gate.settle(nil)
                }
                gate.setTimer(timer)
                if Task.isCancelled {
                    completion.remove(observation)
                    gate.settle(.failure(
                        id: id, command: command,
                        error: AutomationError(code: .appUnavailable, message: "Automation stopped.")
                    ))
                }
            }
        } onCancel: {
            completion.remove(observation)
            gate.settle(.failure(
                id: id, command: command,
                error: AutomationError(code: .appUnavailable, message: "Automation stopped.")
            ))
        }
        completion.remove(observation)
        return outcome ?? .failure(
            id: id, command: command,
            error: AutomationError(code: .timedOut, message: "Automation timed out. Retry with the same request id.")
        )
    }

    /// Answers with whichever lands first: the command's own result, or the
    /// caller's deadline expiring.
    ///
    /// Deliberately not a task group. A group drains its remaining children
    /// before returning and `cancelAll()` is inert against a `Task<_, Never>`,
    /// which ignores cancellation — so racing there would still wait for the
    /// command, and the timeout reply would be written long after the client
    /// (whose read deadline is this same timeout) had hung up. A one-shot gate
    /// settles the race instead, and nothing waits on the loser.
    ///
    /// The command is left running on timeout: it owns app state that cannot be
    /// abandoned mid-flight, and its own completion still populates the replay
    /// cache, so a retry with the same request id collects the real result.
    static func value(
        of work: Task<AutomationResponse, Never>,
        within seconds: TimeInterval,
        id: String,
        command: AutomationCommand
    ) async -> AutomationResponse {
        await self.value(of: work, within: seconds, id: id, command: command, beforeSettling: nil)
    }

    /// Test seam: `beforeSettling` runs once the command has completed and before
    /// its result reaches the gate, with the timer task in hand, so a test can
    /// force the interleaving a starved CI runner produced — a cancelled timer
    /// that runs to completion ahead of the result.
    static func value(
        of work: Task<AutomationResponse, Never>,
        within seconds: TimeInterval,
        id: String,
        command: AutomationCommand,
        beforeSettling: (@Sendable (Task<Void, Never>) async -> Void)?
    ) async -> AutomationResponse {
        let gate = Gate()
        let outcome: AutomationResponse? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let deadline = Task.detached {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    gate.settle(nil)
                }
                gate.setTimer(deadline)
                Task.detached {
                    let response = await work.value
                    await beforeSettling?(deadline)
                    gate.settle(response)
                }
            }
        } onCancel: {
            gate.settle(.failure(
                id: id, command: command,
                error: AutomationError(code: .appUnavailable, message: "Automation stopped before the reply completed.")
            ))
        }
        return outcome ?? .failure(
            id: id,
            command: command,
            error: AutomationError(
                code: .timedOut,
                message: "\(command.rawValue) did not finish within \(Int(seconds))s. "
                    + "Retry with the same request id to collect the result."
            )
        )
    }

    /// One-shot gate: the first caller to `settle` answers the waiter and every
    /// later one is a no-op.
    ///
    /// Cancellation handlers settle synchronously, including cancellation before
    /// continuation registration. No IO or suspension happens under this lock.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AutomationResponse?, Never>?
        private var settled = false
        private var result: AutomationResponse?
        private var timer: Task<Void, Never>?

        func setTimer(_ timer: Task<Void, Never>) {
            let cancel = lock.withLock {
                if settled { return true }
                self.timer = timer
                return false
            }
            if cancel { timer.cancel() }
        }

        func install(_ continuation: CheckedContinuation<AutomationResponse?, Never>) {
            let alreadySettled = lock.withLock {
                if settled { return true }
                self.continuation = continuation
                return false
            }
            if alreadySettled { continuation.resume(returning: result) }
        }

        /// `nil` means the deadline won.
        func settle(_ response: AutomationResponse?) {
            let (continuation, timer) = lock.withLock {
                () -> (CheckedContinuation<AutomationResponse?, Never>?, Task<Void, Never>?) in
                guard !settled else { return (nil, nil) }
                settled = true
                result = response
                defer { self.continuation = nil; self.timer = nil }
                return (self.continuation, self.timer)
            }
            continuation?.resume(returning: response)
            timer?.cancel()
        }

    }
}

/// One command completion, independent of the lifetime of its socket waiters.
final class AutomationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AutomationResponse?
    private var observers: [UUID: @Sendable (AutomationResponse) -> Void] = [:]

    func observe(_ id: UUID, _ observer: @escaping @Sendable (AutomationResponse) -> Void) {
        let completed = lock.withLock { () -> AutomationResponse? in
            if let result { return result }
            observers[id] = observer
            return nil
        }
        if let completed { observer(completed) }
    }

    func remove(_ id: UUID) { lock.withLock { _ = observers.removeValue(forKey: id) } }

    func finish(_ response: AutomationResponse) {
        let callbacks = lock.withLock { () -> [@Sendable (AutomationResponse) -> Void] in
            guard result == nil else { return [] }
            result = response
            defer { observers.removeAll() }
            return Array(observers.values)
        }
        callbacks.forEach { $0(response) }
    }
}
