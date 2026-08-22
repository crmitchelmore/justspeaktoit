import Foundation
import os

// MARK: - xAI bounded finalisation (issue #716)

extension XAILiveClient {
    /// How the last `finishAndWait()` resolved. `confirmedFinal` requires a
    /// provider final event; a delivered commit whose answer never arrived is
    /// only `bestAvailable`, and an undeliverable or stalled commit is a
    /// `transportFailure` — never reported as a clean final (#716).
    enum FinishOutcome: Equatable {
        case confirmedFinal
        case bestAvailable
        case transportFailure
    }

    /// Result of the bounded commit-send bridge.
    enum CommitSendResult {
        case sent
        case failed(Error)
        case timedOut
    }
}

// MARK: - Bounded send bridge (issue #716)

extension XAILiveClient {
    /// Bridges one WebSocket send into async, bounded by the shared deadline
    /// and resumed exactly once: a completion Foundation never invokes, a late
    /// completion after the timeout, or a double invocation can neither hang
    /// the finalisation nor crash nor touch a newer session (#716).
    static func awaitBoundedSend(
        deadline: Date,
        send: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async -> CommitSendResult {
        await withCheckedContinuation { continuation in
            let didResume = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (CommitSendResult) -> Void = { result in
                let shouldResume = didResume.withLock { alreadyResumed -> Bool in
                    guard !alreadyResumed else { return false }
                    alreadyResumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(returning: result)
            }
            send { error in
                if let error {
                    resumeOnce(.failed(error))
                } else {
                    resumeOnce(.sent)
                }
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            DispatchQueue.global().asyncAfter(deadline: .now() + remaining) {
                resumeOnce(.timedOut)
            }
        }
    }
}
