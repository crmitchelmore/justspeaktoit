import Foundation

/// One frame handed to the transport, with the run and send generation that
/// own its completion.
struct LiveOutboundFrame<Run: AnyObject> {
    let run: Run
    let connection: any StreamingWebSocketConnection
    let message: StreamingWebSocketMessage
    let generation: UInt64
    /// The provider's end-of-stream command: it counts as sent only once it is
    /// handed over.
    let endsStream: Bool
}

/// A run whose frames are handed to the transport by one pump owner at a time.
protocol LiveSendPumpRun: AnyObject, Sendable {
    /// A pump loop is handing frames to the transport; everyone else leaves
    /// the next frame to it, so a synchronous completion never recurses.
    var pumping: Bool { get set }
}

/// The bounded single-in-flight pump shared by lock-guarded clients that send
/// exactly one frame at a time. Which frame comes next, what handing it over
/// records and how its completion settles the stream stay with each client.
protocol LiveSingleFlightSending: AnyObject, Sendable {
    associatedtype SendRun: LiveSendPumpRun

    /// Runs `body` under the state lock, then performs the effects it recorded.
    func withState<Value>(_ body: (inout LiveDeferredEffects) -> Value) -> Value
    /// Caller holds the lock: takes the next ready frame and its send
    /// generation, or returns nil when nothing may be sent yet.
    func nextOutbound(_ active: SendRun, _ effects: inout LiveDeferredEffects) -> LiveOutboundFrame<SendRun>?
    /// Caller holds the lock, immediately before `send`: false when the
    /// frame's run no longer owns it, so it is never given to a socket.
    func handOff(_ outbound: LiveOutboundFrame<SendRun>) -> Bool
    /// The transport finished the send of `generation`.
    func completeSend(_ error: Error?, generation: UInt64, _ active: SendRun)
}

extension LiveSingleFlightSending {
    /// Exactly one frame is in flight. Whoever claims a frame owns the pump
    /// until no frame is ready; callers that find it owned leave the next
    /// frame to the owner.
    func pump(_ active: SendRun) {
        let outbound: LiveOutboundFrame<SendRun>? = withState { effects in claim(active, &effects) }
        if let outbound { drive(outbound) }
    }

    /// Takes the next frame and ownership of the pump, or returns nil when the
    /// frame must wait or another caller already owns the pump.
    func claim(_ active: SendRun, _ effects: inout LiveDeferredEffects) -> LiveOutboundFrame<SendRun>? {
        guard !active.pumping, let outbound = nextOutbound(active, &effects) else { return nil }
        active.pumping = true
        return outbound
    }

    /// Sends frames until none is ready. A completion that arrives while
    /// `send` is still on the stack only records its result; this loop then
    /// takes the next frame, so a synchronous transport cannot recurse.
    func drive(_ first: LiveOutboundFrame<SendRun>) {
        let active = first.run
        var next: LiveOutboundFrame<SendRun>? = first
        while let outbound = next {
            // Deferred work runs between claiming a frame and handing it over,
            // and may have cancelled or replaced the run meanwhile: a frame its
            // run no longer owns is never given to a socket.
            guard withState({ _ in handOff(outbound) }) else { return }
            outbound.connection.send(outbound.message) { [weak self, weak active] error in
                guard let self, let active else { return }
                self.completeSend(error, generation: outbound.generation, active)
            }
            next = withState { effects in
                guard let following = nextOutbound(active, &effects) else {
                    active.pumping = false
                    return nil
                }
                return following
            }
        }
    }
}
