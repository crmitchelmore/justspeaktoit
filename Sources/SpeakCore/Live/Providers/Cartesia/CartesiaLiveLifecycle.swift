import Foundation
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - Run lifecycle

extension CartesiaLiveClient {
    var stalledError: Error { StreamingClientError.transportStalled(provider: "Cartesia") }

    /// Runs `body` under the lock, then performs the effects it recorded.
    func withState<Value>(_ body: (inout LiveDeferredEffects) -> Value) -> Value {
        LiveDeferredEffects.applying(under: lock, body)
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

    /// Ends the run for good: its socket is cancelled, admitted audio and its
    /// budget are released, callbacks are dropped and every waiter resumes with
    /// the confirmed transcript.
    func retire(_ active: CartesiaLiveRun, _ effects: inout LiveDeferredEffects) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        let waiters = active.delivery.detach()
        let transcript = active.transcript
        active.connection = nil
        active.outgoing.removeAll()
        active.admittedBytes = 0
        active.inFlightAudioBytes = 0
        active.sending = false
        effects.add {
            connection?.cancel()
            waiters.forEach { $0.resume(returning: transcript) }
        }
    }

    /// Arms a deadline owned by `active`. It acts only while that run is still
    /// current, so a late timer cannot touch a stopped or replacement run.
    func after(
        _ seconds: TimeInterval, _ active: CartesiaLiveRun, _ effects: inout LiveDeferredEffects,
        action: @escaping @Sendable (CartesiaLiveClient, CartesiaLiveRun, inout LiveDeferredEffects) -> Void
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
