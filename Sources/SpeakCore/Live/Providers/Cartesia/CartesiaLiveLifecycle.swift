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

    /// Lifecycle events only: never a key, audio or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "CartesiaLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
