import Foundation

/// One frame handed to the transport, with the run and send generation that
/// own its completion.
struct CartesiaOutbound {
    let run: CartesiaLiveRun
    let connection: any StreamingWebSocketConnection
    let message: StreamingWebSocketMessage
    let generation: UInt64
}

extension CartesiaLiveClient {
    /// Exactly one frame is in flight, and nothing moves before the socket has
    /// opened. Whoever claims a frame owns the pump until no frame is ready;
    /// callers that find it owned leave the next frame to the owner.
    func pump(_ active: CartesiaLiveRun) {
        let outbound: CartesiaOutbound? = withState { effects in claim(active, &effects) }
        if let outbound { drive(outbound) }
    }

    /// Takes the next frame and ownership of the pump, or returns nil when the
    /// frame must wait or another caller already owns the pump.
    func claim(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) -> CartesiaOutbound? {
        guard !active.pumping, let outbound = nextOutbound(active, &effects) else { return nil }
        active.pumping = true
        return outbound
    }

    /// Sends frames until none is ready. A completion that arrives while
    /// `send` is still on the stack only records its result; this loop then
    /// takes the next frame, so a synchronous transport cannot recurse.
    func drive(_ first: CartesiaOutbound) {
        let active = first.run
        var next: CartesiaOutbound? = first
        while let outbound = next {
            // Deferred work runs between claiming a frame and handing it over,
            // and may have cancelled or replaced the run meanwhile: a frame its
            // run no longer owns is never given to a socket.
            guard withState({ _ in owns(outbound) }) else { return }
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

    /// The claimed frame is still the current run's one send, on its socket.
    /// Only the pump owner advances the generation, so a frame fails this only
    /// once its run has been retired.
    private func owns(_ outbound: CartesiaOutbound) -> Bool {
        let active = outbound.run
        return isCurrent(active) && active.sending && active.sendGeneration == outbound.generation
            && active.connection === outbound.connection
    }

    /// Admitted audio first, in capture order; then, once a finish has seen
    /// every audio frame complete, the close command.
    private func nextOutbound(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) -> CartesiaOutbound? {
        guard isCurrent(active), active.opened, !active.sending, let connection = active.connection else { return nil }
        let message: StreamingWebSocketMessage
        if !active.outgoing.isEmpty {
            let audio = active.outgoing.removeFirst()
            active.inFlightAudioBytes = audio.count
            message = .binary(audio)
        } else if active.phase == .finishing, !active.closeSent {
            active.closeSent = true
            active.inFlightAudioBytes = 0
            message = .text(CartesiaLiveProtocol.closeCommand)
            log("Close command sent")
        } else {
            return nil
        }
        active.sending = true
        active.sendGeneration += 1
        let generation = active.sendGeneration
        after(Self.sendDeadline, active, &effects) { client, active, effects in
            guard active.sending, active.sendGeneration == generation else { return }
            client.fail(active, client.stalledError, &effects)
        }
        return CartesiaOutbound(run: active, connection: connection, message: message, generation: generation)
    }

    /// A completion counts only for the run and send that are still current,
    /// so a late completion cannot release a newer frame's budget.
    private func completeSend(_ error: Error?, generation: UInt64, _ active: CartesiaLiveRun) {
        let outbound: CartesiaOutbound? = withState { effects in
            guard isCurrent(active), active.sending, active.sendGeneration == generation else { return nil }
            active.sending = false
            active.admittedBytes -= active.inFlightAudioBytes
            active.inFlightAudioBytes = 0
            if let error {
                fail(active, CartesiaLiveProtocol.connectionError(error), &effects)
                return nil
            }
            if active.closeSent, !active.closeDelivered {
                active.closeDelivered = true
                if let closure = active.peerClosure { settle(closure: closure, active, &effects) }
                return nil
            }
            return claim(active, &effects)
        }
        if let outbound { drive(outbound) }
    }

    /// Stop sequencing: every admitted frame is sent and completed, then
    /// `{"type":"close"}`, then the server's closure ends the stream. Audio held
    /// while the socket opens waits for the handshake within
    /// `finishReadyBudget`, and one deadline bounds the whole finish.
    func beginFinish(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        after(Self.finishBudget, active, &effects) { client, active, effects in
            let error: Error = active.closeDelivered ? CartesiaStreamingError.missingCompletion : client.stalledError
            client.fail(active, error, &effects)
        }
        if !active.opened {
            after(Self.finishReadyBudget, active, &effects) { client, active, effects in
                if !active.opened { client.fail(active, CartesiaStreamingError.sessionNotReady, &effects) }
            }
        }
        if let outbound = claim(active, &effects) {
            effects.add { [weak self] in self?.drive(outbound) }
        }
    }
}
