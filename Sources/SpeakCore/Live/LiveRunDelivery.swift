import Foundation

/// What one lock-guarded run hands to the host and to its finish callers, and
/// the bookkeeping that puts a failure report after everything already handed
/// over. Read and written only under the owning client's lock.
struct LiveRunDelivery {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var waiters: [CheckedContinuation<String?, Never>] = []

    /// Deliveries held back while a finish runs. A healthy finish returns them
    /// in its whole transcript; a failed one releases them before its error,
    /// so the host's visible draft keeps every word the server emitted.
    var withheldFinals: [String] = []
    /// The open turn's latest unconfirmed words, held back likewise.
    var withheldInterim: String?

    /// Transcript callbacks decided under the lock that have not returned yet.
    /// A failure report waits for them, so the host has every word the run
    /// handed over before it learns that the run failed.
    var transcriptsInFlight = 0
    /// The failure report, held until the last in-flight transcript returns.
    var deferredFailureReport: (() -> Void)?
    /// A failure is being published outside the lock: in-flight transcripts,
    /// withheld words, then the error. Finish callers that join meanwhile wait
    /// in `lateWaiters`, so no caller can return before the error is delivered.
    var deliveringFailure = false
    var lateWaiters: [CheckedContinuation<String?, Never>] = []

    /// Drops the host callbacks and withheld words and takes the finish
    /// callers, so a retired run hands nothing more over.
    mutating func detach() -> [CheckedContinuation<String?, Never>] {
        let waiters = self.waiters
        self.waiters.removeAll()
        self.withheldFinals.removeAll()
        self.withheldInterim = nil
        self.onTranscript = nil
        self.onError = nil
        return waiters
    }
}

extension LiveRunFinishing {
    /// Finish callers waiting on the active run, including those held while a
    /// failure is delivered; lets tests observe that a finish has registered
    /// without sleeping.
    var pendingFinishes: Int { withState { _ in run.delivery.waiters.count + run.delivery.lateWaiters.count } }

    /// Retires the run at once, then, outside the lock, publishes the failure
    /// before any finish caller of this run returns: those already waiting and
    /// those that join while it is being delivered. Transcripts already on their
    /// way to the host arrive first: the report waits for them and is released
    /// by the last one to return, on its thread, so no caller blocks on a host
    /// callback. Words a finish had withheld follow, so the host's visible draft
    /// keeps everything the server sent, while finish callers receive confirmed
    /// text only. A callback that starts a new session cannot be touched by
    /// this cleanup: the run is detached, and only its own callers are released.
    func fail(_ active: FinishRun, _ error: Error, _ effects: inout LiveDeferredEffects) {
        guard isCurrent(active) else { return }
        let onTranscript = active.delivery.onTranscript
        let onError = active.delivery.onError
        let finals = active.delivery.withheldFinals
        let interim = active.delivery.withheldInterim
        let waiters = active.delivery.waiters
        let transcript = active.transcript
        active.delivery.waiters.removeAll()
        active.delivery.deliveringFailure = true
        retire(active, &effects)
        log("Session failed")
        let report = {
            if let onTranscript {
                finals.forEach { onTranscript($0, true) }
                if let interim { onTranscript(interim, false) }
            }
            onError?(error)
            waiters.forEach { $0.resume(returning: transcript) }
            self.withState { effects in self.endFailureDelivery(active, &effects) }
        }
        if active.delivery.transcriptsInFlight > 0 {
            active.delivery.deferredFailureReport = report
        } else {
            effects.add(report)
        }
    }

    /// Hands a transcript to the host outside the lock and counts it until the
    /// callback returns, so a failure decided meanwhile is reported after it.
    func deliverTranscript(
        _ text: String, isFinal: Bool, _ active: FinishRun, _ effects: inout LiveDeferredEffects
    ) {
        guard let callback = active.delivery.onTranscript else { return }
        active.delivery.transcriptsInFlight += 1
        effects.add {
            callback(text, isFinal)
            self.withState { effects in self.transcriptReturned(active, &effects) }
        }
    }

    /// A transcript callback returned. The last one out releases a failure
    /// report that was waiting behind it, on this thread and outside the lock.
    private func transcriptReturned(_ active: FinishRun, _ effects: inout LiveDeferredEffects) {
        active.delivery.transcriptsInFlight -= 1
        guard active.delivery.transcriptsInFlight == 0,
              let report = active.delivery.deferredFailureReport else { return }
        active.delivery.deferredFailureReport = nil
        effects.add(report)
    }

    /// The error is out: callers that joined while it was being delivered return.
    private func endFailureDelivery(_ active: FinishRun, _ effects: inout LiveDeferredEffects) {
        active.delivery.deliveringFailure = false
        let late = active.delivery.lateWaiters
        let transcript = active.transcript
        active.delivery.lateWaiters.removeAll()
        effects.add { late.forEach { $0.resume(returning: transcript) } }
    }
}
