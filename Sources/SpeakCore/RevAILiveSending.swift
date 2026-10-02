import Foundation

/// One frame handed to the transport, with the run and send generation that
/// own its completion.
struct RevAIOutbound {
    let run: RevAILiveRun
    let connection: any StreamingWebSocketConnection
    let message: StreamingWebSocketMessage
    let generation: UInt64
    /// `EOS`: it counts as sent only once it is handed over.
    let endsStream: Bool
}

extension RevAILiveClient {
    /// Takes the next frame and ownership of the pump, or returns nil when the
    /// frame must wait or another caller already owns the pump. Whoever claims
    /// a frame owns the pump until no frame is ready.
    func claim(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) -> RevAIOutbound? {
        guard !active.pumping, let outbound = nextOutbound(active, &effects) else { return nil }
        active.pumping = true
        return outbound
    }

    /// Sends frames until none is ready. A completion that arrives while
    /// `send` is still on the stack only records its result; this loop then
    /// takes the next frame, so a synchronous transport cannot recurse.
    func drive(_ first: RevAIOutbound) {
        let active = first.run
        var next: RevAIOutbound? = first
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
    private func owns(_ outbound: RevAIOutbound) -> Bool {
        let active = outbound.run
        return isCurrent(active) && active.sending && active.sendGeneration == outbound.generation
            && active.connection === outbound.connection
    }

    /// Caller holds the lock, immediately before `send` is invoked. `EOS`
    /// counts as sent from here, not while it only waited behind deferred
    /// work: a closure that lands in between did not answer it.
    private func handOff(_ outbound: RevAIOutbound) -> Bool {
        guard owns(outbound) else { return false }
        if outbound.endsStream {
            outbound.run.endOfStreamSent = true
            log("End of stream sent")
        }
        return true
    }

    /// Admitted audio first, in capture order, and only after `connected`;
    /// then, once a finish has seen every audio frame complete, `EOS`.
    private func nextOutbound(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) -> RevAIOutbound? {
        guard isCurrent(active), active.ready, !active.sending, active.sendFailure == nil,
              let connection = active.connection else { return nil }
        let message: StreamingWebSocketMessage
        let endsStream: Bool
        if !active.outgoing.isEmpty {
            let audio = active.outgoing.removeFirst()
            active.inFlightAudioBytes = audio.count
            message = .binary(audio)
            endsStream = false
        } else if active.phase == .finishing, !active.endOfStreamClaimed {
            active.endOfStreamClaimed = true
            active.inFlightAudioBytes = 0
            message = .text(Self.endOfStreamToken)
            endsStream = true
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
        return RevAIOutbound(
            run: active, connection: connection, message: message, generation: generation, endsStream: endsStream
        )
    }

    /// A completion counts only for the run and send that are still current,
    /// so a late completion cannot release a newer frame's budget.
    private func completeSend(_ error: Error?, generation: UInt64, _ active: RevAILiveRun) {
        let outbound: RevAIOutbound? = withState { effects in
            guard isCurrent(active), active.sending, active.sendGeneration == generation else { return nil }
            active.sending = false
            active.admittedBytes -= active.inFlightAudioBytes
            active.inFlightAudioBytes = 0
            if let error {
                sendFailed(error, active, &effects)
                return nil
            }
            if active.endOfStreamSent, !active.endOfStreamDelivered {
                active.endOfStreamDelivered = true
                log("End of stream delivered")
                if let closure = active.peerClosure { settle(closure: closure, active, &effects) }
                return nil
            }
            return claim(active, &effects)
        }
        if let outbound { drive(outbound) }
    }

    /// A failed send ends the stream: nothing more is sent, and `EOS`, if this
    /// was it, was never delivered, so no closure can complete the finish. A
    /// failure that carries the peer's close status (WinHTTP hands the closure
    /// to the pending send too) is reported by that status at once, as is a
    /// closure the receive side already reported. Otherwise the receive side
    /// gets `sendFailureGrace` to report the closure that explains the broken
    /// socket, such as 4003 for exhausted credit, before the send's own error
    /// is published.
    private func sendFailed(_ error: Error, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        if (error as? StreamingWebSocketCloseReporting)?.webSocketCloseCode != nil {
            fail(active, interruption(by: error), &effects)
            return
        }
        if let closure = active.peerClosure {
            fail(active, interruption(by: closure), &effects)
            return
        }
        active.sendFailure = error
        log("Send failed")
        after(Self.sendFailureGrace, active, &effects) { client, active, effects in
            if let failure = active.sendFailure { client.fail(active, failure, &effects) }
        }
    }

    /// Stop sequencing: every admitted frame is sent and completed, then `EOS`,
    /// then the trailing final and the server's normal closure end the stream.
    /// Audio held until `connected` waits for it within `finishReadyBudget`,
    /// and one deadline bounds the whole finish. A run that never admitted
    /// audio has nothing to transcribe and closes at once.
    func beginFinish(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        guard active.admittedAudio else {
            log("Finished without audio")
            retire(active, &effects)
            return
        }
        after(RevAIStreaming.finishBudget, active, &effects) { client, active, effects in
            let error: Error
            if let failure = active.sendFailure {
                error = failure
            } else if !active.ready {
                error = RevAILiveError.sessionNotReady
            } else if active.endOfStreamDelivered {
                error = RevAILiveError.missingCompletion
            } else {
                error = client.stalledError
            }
            client.fail(active, error, &effects)
        }
        if !active.ready {
            after(Self.finishReadyBudget, active, &effects) { client, active, effects in
                if !active.ready { client.fail(active, RevAILiveError.sessionNotReady, &effects) }
            }
        }
        if let outbound = claim(active, &effects) {
            effects.add { [weak self] in self?.drive(outbound) }
        }
    }
}
