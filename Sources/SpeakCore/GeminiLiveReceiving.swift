import Foundation

extension GeminiLiveClient {
    /// One receive is outstanding per socket. A completion delivered while the
    /// loop is still inside `receive` is handed back to the loop, so a
    /// transport that answers synchronously from a buffer cannot grow the stack.
    /// The loop ends once its socket is no longer the run's.
    func receive(_ active: GeminiLiveRun, _ connection: any StreamingWebSocketConnection) {
        while let generation: UInt64 = withState({ _ in armReceive(active, connection) }) {
            connection.receive { [weak self, weak active] result in
                guard let self, let active else { return }
                let handedBack: Bool = self.withState { _ in
                    guard active.receiveArming, active.receiveGeneration == generation else { return false }
                    active.synchronousReceive = result
                    return true
                }
                guard !handedBack else { return }
                if self.handle(result, generation, active, connection) { self.receive(active, connection) }
            }
            let handedBack: Result<StreamingWebSocketMessage, Error>? = withState { _ in
                active.receiveArming = false
                defer { active.synchronousReceive = nil }
                return active.synchronousReceive
            }
            guard let result = handedBack, handle(result, generation, active, connection) else { return }
        }
    }

    private func armReceive(_ active: GeminiLiveRun, _ connection: any StreamingWebSocketConnection) -> UInt64? {
        guard isCurrent(active), active.connection === connection else { return nil }
        active.receiveGeneration += 1
        active.receiveArming = true
        active.synchronousReceive = nil
        return active.receiveGeneration
    }

    /// Applies one receive result and answers whether the loop continues.
    /// Frames are decoded before the lock is taken; a server may send its
    /// JSON as text or binary frames.
    private func handle(
        _ result: Result<StreamingWebSocketMessage, Error>, _ generation: UInt64, _ active: GeminiLiveRun,
        _ connection: any StreamingWebSocketConnection
    ) -> Bool {
        let events: [GeminiLiveEvent]
        switch result {
        case .success(.text(let text)): events = GeminiLiveProtocol.events(in: Data(text.utf8))
        case .success(.binary(let data)): events = GeminiLiveProtocol.events(in: data)
        case .failure: events = []
        }
        return withState { effects in
            guard owns(connection, active), active.receiveGeneration == generation else { return false }
            if case .failure(let error) = result {
                closed(by: error, active, &effects)
                return false
            }
            for event in events where owns(connection, active) {
                apply(event, active, &effects)
            }
            return owns(connection, active)
        }
    }

    private func owns(_ connection: any StreamingWebSocketConnection, _ active: GeminiLiveRun) -> Bool {
        isCurrent(active) && active.connection === connection
    }

    private func apply(_ event: GeminiLiveEvent, _ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        switch event {
        case .setupComplete:
            markReady(active, &effects)
        case .interimTranscript(let text):
            showInterim(text, active, &effects)
        case .finalTranscript(let text):
            confirm(text, active, &effects)
            turnEnded(active, &effects)
        case .turnComplete:
            turnEnded(active, &effects)
        case .goAway:
            beginHandover(active, &effects)
        case .failure(let code, let status, let message):
            fail(active, Self.mapServerFailure(code: code, status: status, message: message), &effects)
        }
    }

    /// `setupComplete` answers this socket's setup: held audio may move. One
    /// that arrives before the setup was sent answers nothing and is ignored.
    private func markReady(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard active.setupClaimed, !active.ready else { return }
        active.ready = true
        log("Setup completed")
        if let outbound = claim(active, &effects) {
            effects.add { [weak self] in self?.drive(outbound) }
        }
    }

    /// The utterance in flight, restated in full. While a finish runs it is
    /// held back, to be released only if the finish fails.
    private func showInterim(_ text: String, _ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard !text.isEmpty else { return }
        active.openUtterance = text
        guard active.phase != .finishing else {
            active.withheldDraft = text
            return
        }
        deliver(text, isFinal: false, active, &effects)
    }

    /// A finalised utterance is confirmed once, by order: the Live API sends
    /// no utterance identity, so identical text in two finals is two
    /// utterances. A finish folds finals that arrive during it into its return
    /// instead of delivering them.
    private func confirm(_ text: String, _ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        active.openUtterance = nil
        active.withheldDraft = nil
        guard !text.isEmpty else { return }
        active.accumulated.append(final: text)
        guard active.phase != .finishing else {
            active.withheldFinals.append(text)
            return
        }
        deliver(text, isFinal: true, active, &effects)
    }

    /// Hands a transcript to the host outside the lock and counts it until the
    /// callback returns, so a failure decided meanwhile is reported after it.
    private func deliver(
        _ text: String, isFinal: Bool, _ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects
    ) {
        guard let callback = active.onTranscript else { return }
        active.transcriptsInFlight += 1
        effects.add {
            callback(text, isFinal)
            self.withState { effects in self.transcriptReturned(active, &effects) }
        }
    }

    /// The server ended a turn. Only a turn end after `audioStreamEnd` was
    /// handed over can answer it, and only once no utterance remains open: a
    /// `turnComplete` that overtakes the open utterance's final waits for it.
    private func turnEnded(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard active.streamEndSent else { return }
        active.turnEnded = true
        settleIfAnswered(active, &effects)
    }

    /// `audioStreamEnd` completed on the transport. A turn end that arrived
    /// before this answers it now; otherwise the server has `trailingSettle`
    /// to finalise audio it had not reported. It sends nothing for silence, so
    /// with no utterance open the quiet period ends the stream; an interim
    /// that arrives meanwhile opens an utterance whose final is then awaited.
    func streamEndDelivered(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        active.streamEndDelivered = true
        log("Audio stream end delivered")
        let socket = active.socketGeneration
        after(Self.trailingSettle, active, &effects) { client, active, effects in
            guard active.socketGeneration == socket, active.streamEndDelivered, active.openUtterance == nil else {
                return
            }
            client.streamEnded(active, &effects)
        }
        settleIfAnswered(active, &effects)
    }

    private func settleIfAnswered(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard active.streamEndDelivered, active.turnEnded, active.openUtterance == nil else { return }
        streamEnded(active, &effects)
    }

    /// The current socket has transcribed everything it was sent. A finish
    /// with nothing left to send completes; a handover with audio still
    /// admitted continues on a new socket.
    func streamEnded(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard active.streamEndDelivered else { return }
        if active.phase == .finishing, active.outgoing.isEmpty {
            log("Stream completed")
            retire(active, &effects)
        } else if active.handingOver {
            handOver(active, &effects)
        }
    }

    /// Replaces the socket that `goAway` retired. Its callbacks stop counting
    /// the moment it is detached; the new socket repeats the setup and takes
    /// the admitted audio, in order, once it is ready.
    private func handOver(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard let request = active.request else { return }
        let retired = active.connection
        active.resetSocket()
        log("Handing over to a new session")
        armReadyDeadline(active, &effects)
        effects.add { [weak self] in
            retired?.cancel()
            self?.connect(active, request: request)
        }
    }

    /// The receive failed: the server closed the socket or the transport
    /// broke. A socket being handed over that has already delivered
    /// `audioStreamEnd`, with no utterance open, may close before answering:
    /// the recording continues on its replacement. Any other closure fails the
    /// run: a finish never completes without the server's answer. The words it
    /// withheld still reach the host and the confirmed text is returned.
    private func closed(by error: Error, _ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        if active.handingOver, active.phase != .finishing, active.streamEndDelivered, active.openUtterance == nil {
            handOver(active, &effects)
            return
        }
        let failure: Error
        if active.openUtterance != nil, active.streamEndSent {
            failure = GeminiLiveStreamingError.incompleteUtterance
        } else {
            failure = GeminiLiveProtocol.connectionError(error)
        }
        fail(active, failure, &effects)
    }
}
