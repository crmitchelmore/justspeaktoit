import Foundation

/// One frame handed to the transport, with the run and send generation that
/// own its completion.
struct CartesiaOutbound {
    let run: CartesiaLiveRun
    let connection: any StreamingWebSocketConnection
    let message: StreamingWebSocketMessage
    let generation: UInt64
    /// `{"type":"close"}`: it counts as sent only once it is handed over.
    let closesStream: Bool
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

    /// The claimed frame is still the current run's one send, on its socket.
    /// Only the pump owner advances the generation, so a frame fails this only
    /// once its run has been retired.
    private func owns(_ outbound: CartesiaOutbound) -> Bool {
        let active = outbound.run
        return isCurrent(active) && active.sending && active.sendGeneration == outbound.generation
            && active.connection === outbound.connection
    }

    /// Caller holds the lock, immediately before `send` is invoked. The close
    /// command counts as sent from here, not while it only waited behind
    /// deferred work: a closure that lands in between did not answer it.
    private func handOff(_ outbound: CartesiaOutbound) -> Bool {
        guard owns(outbound) else { return false }
        if outbound.closesStream {
            outbound.run.closeSent = true
            log("Close command sent")
        }
        return true
    }

    /// Admitted audio first, in capture order; then, once a finish has seen
    /// every audio frame complete, the close command.
    private func nextOutbound(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) -> CartesiaOutbound? {
        guard isCurrent(active), active.opened, !active.sending, let connection = active.connection else { return nil }
        let message: StreamingWebSocketMessage
        let closesStream: Bool
        if !active.outgoing.isEmpty {
            let audio = active.outgoing.removeFirst()
            active.inFlightAudioBytes = audio.count
            message = .binary(audio)
            closesStream = false
        } else if active.phase == .finishing, !active.closeClaimed {
            active.closeClaimed = true
            active.inFlightAudioBytes = 0
            message = .text(CartesiaLiveProtocol.closeCommand)
            closesStream = true
        } else {
            return nil
        }
        active.sending = true
        active.sendGeneration += 1
        let generation = active.sendGeneration
        after(timing.send, active, &effects) { client, active, effects in
            guard active.sending, active.sendGeneration == generation else { return }
            client.fail(active, client.stalledError, &effects)
        }
        return CartesiaOutbound(
            run: active, connection: connection, message: message, generation: generation, closesStream: closesStream
        )
    }

    /// A completion counts only for the run and send that are still current,
    /// so a late completion cannot release a newer frame's budget.
    private func completeSend(_ error: Error?, generation: UInt64, _ active: CartesiaLiveRun) {
        let outbound: CartesiaOutbound? = withState { effects in
            guard isCurrent(active), active.sending, active.sendGeneration == generation else { return nil }
            active.sending = false
            active.admittedBytes -= active.inFlightAudioBytes
            active.inFlightAudioBytes = 0
            // A spurious ENOTCONN on a send is ignored, as it always has been:
            // the receive side decides whether the socket is really gone.
            if let error, !WebSocketErrorFilter.isSpuriousDisconnect(error) {
                fail(active, CartesiaLiveProtocol.connectionError(error), &effects)
                return nil
            }
            if active.closeSent, !active.closeDelivered {
                active.closeDelivered = true
                if let closure = active.peerClosure {
                    settle(closure: closure, active, &effects)
                } else {
                    awaitClosure(active, &effects)
                }
                return nil
            }
            return claim(active, &effects)
        }
        if let outbound { drive(outbound) }
    }

    /// Queues one framed PCM frame. Before the socket opens it joins the
    /// startup audio, which `trimStartupAudio` keeps to the newest
    /// `bufferedAudioSeconds`. Once it has opened, a backlog beyond that bound
    /// is a stalled transport, reported once.
    func admit(_ frame: Data, _ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) -> Bool {
        guard !frame.isEmpty else { return true }
        if active.opened, active.admittedBytes + frame.count > active.maximumBytes {
            fail(active, stalledError, &effects)
            return false
        }
        active.outgoing.append(frame)
        active.admittedBytes += frame.count
        return true
    }

    /// Startup audio keeps the newest `bufferedAudioSeconds`, counting the
    /// framer's partial frame: the oldest frames make room while the socket
    /// opens, instead of failing the recording.
    func trimStartupAudio(_ active: CartesiaLiveRun) {
        guard !active.opened else { return }
        while active.admittedBytes + active.framer.bufferedByteCount > active.maximumBytes,
              !active.outgoing.isEmpty {
            active.admittedBytes -= active.outgoing.removeFirst().count
        }
    }

    /// Stop sequencing: the framer's padded tail joins the admitted audio,
    /// every frame is sent and completed, then exactly one `{"type":"close"}`.
    /// The drain, including any wait for the handshake, must deliver `close`
    /// within `finishBudget`; after it the results are read until the server's
    /// normal closure or the post-stop budget.
    func beginFinish(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        if let tail = active.framer.finish(), !admit(tail, active, &effects) { return }
        after(timing.drain, active, &effects) { client, active, effects in
            guard !active.closeDelivered else { return }
            client.fail(active, active.opened ? client.stalledError : CartesiaStreamingError.sessionNotReady, &effects)
        }
        if let outbound = claim(active, &effects) {
            effects.add { [weak self] in self?.drive(outbound) }
        }
    }

    /// `close` is with the server: results are read until its normal closure
    /// or until the post-stop budget (and any stop grace) elapses, and either
    /// way the finish returns the whole session.
    private func awaitClosure(_ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        after(timing.postClose, active, &effects) { client, active, effects in
            guard active.phase == .finishing else { return }
            client.complete(active, &effects)
        }
    }
}
