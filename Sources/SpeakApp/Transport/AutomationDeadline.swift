#if os(macOS)
import Foundation
import SpeakCore

/// Bounds how long an automation client waits, without abandoning the command it
/// is waiting on.
///
/// Separate from `AutomationServer` because the two answer different questions:
/// the server owns the socket and the idempotency caches, this owns the race
/// between a running command and the caller's patience.
enum AutomationDeadline {
    /// Answers with whichever lands first: the command's own result, or the
    /// caller's deadline expiring.
    ///
    /// Deliberately not a task group. A group drains its remaining children
    /// before returning and `cancelAll()` is inert against a `Task<_, Never>`,
    /// which ignores cancellation — so racing there would still wait for the
    /// command, and the timeout reply would be written long after the client
    /// (whose socket read deadline is this same timeout) had hung up. A one-shot
    /// gate settles the race instead, and nothing waits on the loser.
    ///
    /// The command is left running on timeout: it owns app state that cannot be
    /// abandoned mid-flight, and its own completion still populates the server's
    /// replay cache, so a retry with the same request id collects the real result.
    static func value(
        of work: Task<AutomationResponse, Never>,
        within seconds: TimeInterval,
        id: String,
        command: AutomationCommand
    ) async -> AutomationResponse {
        await value(of: work, within: seconds, id: id, command: command, beforeSettling: nil)
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
        let outcome: AutomationResponse? = await withCheckedContinuation { continuation in
            let gate = Gate(continuation: continuation)
            let deadline = Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                // A cancelled timer lost the race. Without this guard the sleep
                // returns the instant the command cancels it, and on a starved
                // machine the timer could reach the gate before the command's own
                // result did — reporting a finished command as timed out.
                guard !Task.isCancelled else { return }
                await gate.settle(nil)
            }
            Task.detached {
                let response = await work.value
                await beforeSettling?(deadline)
                // Settle first, so the result is what answers the waiter; then
                // release the timer rather than leaving it asleep for the rest of
                // a long deadline.
                await gate.settle(response)
                deadline.cancel()
            }
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
    /// An actor rather than a lock because both racers are already async, and the
    /// once-only guarantee is what makes resuming a checked continuation from two
    /// separate tasks safe.
    private actor Gate {
        private var continuation: CheckedContinuation<AutomationResponse?, Never>?

        init(continuation: CheckedContinuation<AutomationResponse?, Never>) {
            self.continuation = continuation
        }

        /// `nil` means the deadline won.
        func settle(_ response: AutomationResponse?) {
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            continuation.resume(returning: response)
        }
    }
}
#endif
