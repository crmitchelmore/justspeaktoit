#if os(iOS)
import ActivityKit
import Foundation

// Ordered Live Activity publication (issue #983).
//
// ActivityKit gives no ordering guarantee across concurrent `update` calls, and
// the activity is reused across runs. Submitting each publication as its own
// unstructured task therefore let an older state land after a newer one — the
// `.arming` write completing after proven capture, or a previous run's snippet
// landing during its successor's preparation. Everything that decides *whether*
// a publication may still be applied lives in `ActivityPublicationOrder`, where
// `swift test` proves it; this file is the plumbing.
@MainActor
extension TranscriptionActivityManager {
    /// Submits one content publication, ordered behind everything already
    /// queued and skipped if a newer publication supersedes it before it runs.
    func publish(
        _ state: TranscriptionActivityAttributes.ContentState,
        to activity: Activity<TranscriptionActivityAttributes>
    ) {
        guard let ticket = order.submit() else { return }
        latestState = state
        enqueuePublication { [weak self] in
            guard let self, self.order.isCurrent(ticket) else { return }
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// Chains asynchronous activity work so it is applied in submission order.
    func enqueuePublication(_ body: @escaping @MainActor () async -> Void) {
        let previous = publishChain
        publishChain = Task { @MainActor in
            await previous?.value
            await body()
        }
    }
}
#endif
