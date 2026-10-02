import Foundation
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - Run lifecycle

extension CartesiaLiveClient {
    var stalledError: Error { StreamingClientError.transportStalled(provider: "Cartesia") }

    /// Finish callers waiting on the active run, including those held while a
    /// failure is delivered; lets tests observe that a finish has registered
    /// without sleeping.
    var pendingFinishes: Int { withState { _ in run.waiters.count + run.lateWaiters.count } }

    /// Runs `body` under the lock, then performs the effects it recorded.
    func withState<Value>(_ body: (inout CartesiaLiveEffects) -> Value) -> Value {
        var effects = CartesiaLiveEffects()
        let value = lock.withLock { body(&effects) }
        effects.perform()
        return value
    }

    func isCurrent(_ active: CartesiaLiveRun) -> Bool { active === run && active.phase != .closed }

    /// Records the handshake, from the transport or the `connected` frame.
    /// Returns whether this call opened the run.
    func recordOpen(_ active: CartesiaLiveRun) -> Bool {
        guard isCurrent(active), active.connection != nil, !active.opened else { return false }
        active.opened = true
        if active.phase == .connecting { active.phase = .streaming }
        log("WebSocket handshake completed")
        return true
    }

    /// Retires the run at once, then, outside the lock, publishes the failure
    /// before any finish caller of this run returns: those already waiting and
    /// those that join while it is being delivered. Transcripts already on their
    /// way to the host arrive first: the report waits for them and is released
    /// by the last one to return, on its thread, so no caller blocks on a host
    /// callback. Words a finish had withheld follow, so the host's visible draft
    /// keeps everything the server sent, while finish callers receive confirmed
    /// text only. A callback that starts a new session cannot be touched by
    /// this cleanup: the run is detached, and only its own callers are released.
    func fail(_ active: CartesiaLiveRun, _ error: Error, _ effects: inout CartesiaLiveEffects) {
        guard isCurrent(active) else { return }
        let onTranscript = active.onTranscript
        let onError = active.onError
        let finals = active.withheldFinals
        let draft = active.withheldDraft
        let waiters = active.waiters
        let transcript = active.transcript
        active.waiters.removeAll()
        active.deliveringFailure = true
        retire(active, &effects)
        log("Session failed")
        let report = {
            if let onTranscript {
                finals.forEach { onTranscript($0, true) }
                if let draft { onTranscript(draft, false) }
            }
            onError?(error)
            waiters.forEach { $0.resume(returning: transcript) }
            self.withState { effects in self.endFailureDelivery(active, &effects) }
        }
        if active.transcriptsInFlight > 0 {
            active.deferredFailureReport = report
        } else {
            effects.add(report)
        }
    }

    /// A transcript callback returned. The last one out releases a failure
    /// report that was waiting behind it, on this thread and outside the lock.
    func transcriptReturned(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        active.transcriptsInFlight -= 1
        guard active.transcriptsInFlight == 0, let report = active.deferredFailureReport else { return }
        active.deferredFailureReport = nil
        effects.add(report)
    }

    /// The error is out: callers that joined while it was being delivered return.
    private func endFailureDelivery(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        active.deliveringFailure = false
        let late = active.lateWaiters
        let transcript = active.transcript
        active.lateWaiters.removeAll()
        effects.add { late.forEach { $0.resume(returning: transcript) } }
    }

    /// Ends the run for good: its socket is cancelled, admitted audio and its
    /// budget are released, callbacks are dropped and every waiter resumes with
    /// the confirmed transcript.
    func retire(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        let waiters = active.waiters
        let transcript = active.transcript
        active.connection = nil
        active.outgoing.removeAll()
        active.admittedBytes = 0
        active.inFlightAudioBytes = 0
        active.sending = false
        active.waiters.removeAll()
        active.withheldFinals.removeAll()
        active.withheldDraft = nil
        active.onTranscript = nil
        active.onError = nil
        effects.add {
            connection?.cancel()
            waiters.forEach { $0.resume(returning: transcript) }
        }
    }

    /// Arms a deadline owned by `active`. It acts only while that run is still
    /// current, so a late timer cannot touch a stopped or replacement run.
    func after(
        _ seconds: TimeInterval, _ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects,
        action: @escaping @Sendable (CartesiaLiveClient, CartesiaLiveRun, inout CartesiaLiveEffects) -> Void
    ) {
        let schedule = self.schedule
        effects.add {
            schedule(seconds) { [weak self, weak active] in
                guard let self, let active else { return }
                self.withState { effects in
                    if self.isCurrent(active) { action(self, active, &effects) }
                }
            }
        }
    }

    /// Lifecycle events only: never a key, audio or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "CartesiaLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
