import Foundation

/// One frame handed to the transport, with the run, socket and send generation
/// that own its completion.
struct GeminiOutbound {
    enum Payload {
        /// The socket's first frame.
        case setup(String)
        /// Admitted PCM, encoded outside the lock just before it is sent.
        case audio(Data)
        /// `audioStreamEnd`: it counts as sent only once it is handed over.
        case streamEnd
    }

    let run: GeminiLiveRun
    let connection: any StreamingWebSocketConnection
    let payload: Payload
    let generation: UInt64

    func message(sampleRate: Int) -> StreamingWebSocketMessage {
        switch payload {
        case .setup(let setup): return .text(setup)
        case .audio(let audio): return .text(GeminiLiveProtocol.audioMessage(audio, sampleRate: sampleRate))
        case .streamEnd: return .text(GeminiLiveProtocol.audioStreamEnd)
        }
    }
}

extension GeminiLiveClient {
    /// Exactly one frame is in flight, and nothing moves before the socket has
    /// opened. Whoever claims a frame owns the pump until no frame is ready;
    /// callers that find it owned leave the next frame to the owner.
    func pump(_ active: GeminiLiveRun) {
        let outbound: GeminiOutbound? = withState { effects in claim(active, &effects) }
        if let outbound { drive(outbound) }
    }

    /// Takes the next frame and ownership of the pump, or returns nil when the
    /// frame must wait or another caller already owns the pump.
    func claim(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) -> GeminiOutbound? {
        guard !active.pumping, let outbound = nextOutbound(active, &effects) else { return nil }
        active.pumping = true
        return outbound
    }

    /// Sends frames until none is ready. A completion that arrives while
    /// `send` is still on the stack only records its result; this loop then
    /// takes the next frame, so a synchronous transport cannot recurse.
    func drive(_ first: GeminiOutbound) {
        let active = first.run
        var next: GeminiOutbound? = first
        while let outbound = next {
            // Deferred work runs between claiming a frame and handing it over,
            // and may have cancelled or replaced the run or its socket
            // meanwhile: a frame they no longer own is never given to a socket.
            guard withState({ _ in handOff(outbound) }) else { return }
            let connection = outbound.connection
            connection.send(outbound.message(sampleRate: sampleRate)) { [weak self, weak active] error in
                guard let self, let active else { return }
                self.completeSend(error, generation: outbound.generation, connection, active)
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
    /// once its run or socket has been retired.
    private func owns(_ outbound: GeminiOutbound) -> Bool {
        let active = outbound.run
        return isCurrent(active) && active.sending && active.sendGeneration == outbound.generation
            && active.connection === outbound.connection
    }

    /// Caller holds the lock, immediately before `send` is invoked. The end of
    /// the audio counts as sent from here, not while it only waited behind
    /// deferred work: an event that lands in between did not answer it.
    private func handOff(_ outbound: GeminiOutbound) -> Bool {
        guard owns(outbound) else {
            outbound.run.pumping = false
            return false
        }
        if case .streamEnd = outbound.payload {
            outbound.run.streamEndSent = true
            log("Audio stream end sent")
        }
        return true
    }

    /// The setup first, on every socket; then, once the session is ready,
    /// admitted audio in capture order; then, when a finish has seen every
    /// audio frame complete or a `goAway` is handing the socket over,
    /// `audioStreamEnd`. A socket being handed over takes no more audio: what
    /// is admitted meanwhile waits for its replacement.
    private func nextOutbound(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) -> GeminiOutbound? {
        guard isCurrent(active), active.opened, !active.sending, let connection = active.connection else { return nil }
        let payload: GeminiOutbound.Payload
        if !active.setupClaimed {
            active.setupClaimed = true
            active.inFlightAudioBytes = 0
            payload = .setup(active.setupMessage)
        } else if !active.ready {
            return nil
        } else if !active.handingOver, !active.outgoing.isEmpty {
            let audio = active.outgoing.removeFirst()
            active.inFlightAudioBytes = audio.count
            payload = .audio(audio)
        } else if active.handingOver || active.phase == .finishing, !active.streamEndClaimed {
            active.streamEndClaimed = true
            active.inFlightAudioBytes = 0
            payload = .streamEnd
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
        return GeminiOutbound(run: active, connection: connection, payload: payload, generation: generation)
    }

    /// A completion counts only for the run, socket and send that are still
    /// current, so a late completion cannot release a newer frame's budget.
    private func completeSend(
        _ error: Error?, generation: UInt64, _ connection: any StreamingWebSocketConnection, _ active: GeminiLiveRun
    ) {
        let outbound: GeminiOutbound? = withState { effects in
            guard isCurrent(active), active.sending, active.sendGeneration == generation,
                  active.connection === connection else { return nil }
            active.sending = false
            active.admittedBytes -= active.inFlightAudioBytes
            // Audio reached a session, so a later `goAway` is not a storm.
            if active.inFlightAudioBytes > 0 { active.handoversWithoutAudio = 0 }
            active.inFlightAudioBytes = 0
            if let error {
                fail(active, GeminiLiveProtocol.connectionError(error), &effects)
                return nil
            }
            if active.streamEndSent, !active.streamEndDelivered {
                streamEndDelivered(active, &effects)
                return nil
            }
            return claim(active, &effects)
        }
        if let outbound { drive(outbound) }
    }

    /// Stop sequencing: every admitted frame is sent and completed, then
    /// `audioStreamEnd`, then the server's answer ends the stream. Audio held
    /// while the session sets up waits for `setupComplete` within
    /// `finishReadyBudget`, and one deadline bounds the whole finish.
    func beginFinish(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        log("Finishing")
        after(Self.finishBudget, active, &effects) { client, active, effects in
            client.fail(active, client.expiredError(active), &effects)
        }
        if !active.ready {
            let socket = active.socketGeneration
            after(Self.finishReadyBudget, active, &effects) { client, active, effects in
                guard active.socketGeneration == socket, !active.ready else { return }
                client.fail(active, GeminiLiveStreamingError.sessionNotReady, &effects)
            }
        }
        if let outbound = claim(active, &effects) {
            effects.add { [weak self] in self?.drive(outbound) }
        }
    }

    /// `goAway`: the server will end this session, so its utterance is flushed
    /// and the run continues on a new socket once the flush is answered. A
    /// server that ends a replacement before it has accepted any audio ends the
    /// run instead, so this can never become a reconnect storm.
    func beginHandover(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard !active.handingOver else { return }
        guard active.ready, active.handoversWithoutAudio == 0 else {
            fail(active, GeminiLiveStreamingError.sessionEnded, &effects)
            return
        }
        active.handingOver = true
        active.handoversWithoutAudio += 1
        log("Session ending; handing over")
        let socket = active.socketGeneration
        after(Self.finishBudget, active, &effects) { client, active, effects in
            guard active.socketGeneration == socket, active.handingOver else { return }
            client.fail(active, client.expiredError(active), &effects)
        }
        if let outbound = claim(active, &effects) {
            effects.add { [weak self] in self?.drive(outbound) }
        }
    }
}
