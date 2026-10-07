import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension GladiaLiveClient {
    // MARK: - Session request (step 1)

    /// Validates the configuration, then requests the session. Caller holds
    /// the lock.
    func begin(_ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard !apiKey.isEmpty else {
            fail(StreamingClientError.missingAPIKey(provider: "Gladia"), active, &effects)
            return
        }
        guard GladiaLiveProtocol.supportedSampleRates.contains(sampleRate) else {
            fail(GladiaStreamingError.invalidSampleRate(sampleRate), active, &effects)
            return
        }
        guard let body = GladiaLiveProtocol.initBody(model: model, language: language, sampleRate: sampleRate) else {
            fail(StreamingClientError.invalidURL, active, &effects)
            return
        }
        let request = GladiaLiveProtocol.initRequest(endpoint: endpoint, apiKey: apiKey, body: body)
        active.stage = .initiating
        arm(Self.readyDeadline, active, &effects) { client, active, effects in
            if active.stage != .open { client.fail(GladiaStreamingError.sessionNotReady, active, &effects) }
        }
        effects.append { [self] in initiate(active, request) }
        log("Gladia live session requested")
    }

    /// Outside the lock, and possibly long after `begin` decided it (behind a
    /// held scheduler, say): a run retired meanwhile never starts the
    /// authenticated request. Once it exists the request is retained by its
    /// run; a run that closes while it is being created abandons it at once.
    private func initiate(_ active: GladiaLiveRun, _ request: URLRequest) {
        guard perform({ _ in isCurrent(active) && active.stage == .initiating && active.sessionRequest == nil }) else {
            return
        }
        let pending = initiateSession(request) { [weak self, weak active] result in
            guard let self, let active else { return }
            self.sessionReplied(result, active)
        }
        perform { effects in
            if isCurrent(active), active.stage == .initiating {
                active.sessionRequest = pending
            } else if active.stage == .closed {
                effects.append { pending.cancel() }
            }
        }
    }

    private func sessionReplied(_ result: Result<(statusCode: Int, body: Data), Error>, _ active: GladiaLiveRun) {
        perform { effects in
            guard isCurrent(active), active.stage == .initiating else { return }
            active.sessionRequest = nil
            let outcome = result.flatMap { reply in
                GladiaLiveProtocol.sessionURL(statusCode: reply.statusCode, body: reply.body, endpoint: endpoint)
            }
            switch outcome {
            case .failure(let error):
                // Transport errors can carry the request; only typed errors pass.
                let typed = error is GladiaStreamingError || error is StreamingClientError
                fail(typed ? error : GladiaStreamingError.sessionRequestFailed, active, &effects)
            case .success(let url):
                active.stage = .connecting
                log("Gladia live session created")
                effects.append { [self] in connect(active, to: url) }
            }
        }
    }

    // MARK: - Socket (step 2)

    /// Outside the lock. The session URL authenticates itself, so the request
    /// carries no account key. A run retired before this effect ran creates no
    /// socket; one retired while it was being created cancels it.
    private func connect(_ active: GladiaLiveRun, to url: URL) {
        guard perform({ _ in isCurrent(active) && active.stage == .connecting && active.connection == nil }) else {
            return
        }
        let connection = makeConnection(URLRequest(url: url))
        let generation: UInt64? = perform { effects in
            guard isCurrent(active), active.stage == .connecting, active.connection == nil else {
                effects.append { connection.cancel() }
                return nil
            }
            active.connection = connection
            active.receiveGeneration &+= 1
            active.receiveCallActive = true
            return active.receiveGeneration
        }
        guard let generation else { return }
        // Retired since the socket was stored: `close` has cancelled it.
        guard perform({ _ in isCurrent(active) && active.connection === connection }) else { return }
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.socketOpened(active)
        }
        receiveLoop(active, connection, generation: generation)
    }

    /// The real handshake, never `task.state`, releases admitted audio.
    private func socketOpened(_ active: GladiaLiveRun) {
        perform { effects in
            guard isCurrent(active), active.stage == .connecting else { return }
            active.stage = .open
            log("Gladia WebSocket handshake completed")
            startNextSend(active, &effects)
        }
    }

    // MARK: - Receive

    /// One receive is outstanding at a time. A completion that arrives before
    /// `receive` returns is parked and handled by this loop, so a transport
    /// that answers synchronously cannot grow the stack. A run retired while
    /// its callbacks were delivered issues no further receive.
    private func receiveLoop(
        _ active: GladiaLiveRun, _ connection: any StreamingWebSocketConnection, generation: UInt64
    ) {
        var next: UInt64? = generation
        while let current = next {
            guard perform({ _ in
                isCurrent(active) && active.receiveGeneration == current && active.receiveCallActive
            }) else { return }
            connection.receive { [weak self, weak active] result in
                guard let self, let active else { return }
                self.received(result, generation: current, active)
            }
            next = perform { effects in
                guard active.receiveGeneration == current, active.receiveCallActive else { return nil }
                active.receiveCallActive = false
                guard let result = active.earlyReceive else { return nil }
                active.earlyReceive = nil
                return handleReceive(result, active, &effects)
            }
        }
    }

    private func received(
        _ result: Result<StreamingWebSocketMessage, Error>, generation: UInt64, _ active: GladiaLiveRun
    ) {
        let resume: (generation: UInt64, connection: any StreamingWebSocketConnection)? = perform { effects in
            guard isCurrent(active), active.receiveGeneration == generation else { return nil }
            if active.receiveCallActive {
                active.earlyReceive = result
                return nil
            }
            guard let next = handleReceive(result, active, &effects), let connection = active.connection else {
                return nil
            }
            return (next, connection)
        }
        guard let resume else { return }
        receiveLoop(active, resume.connection, generation: resume.generation)
    }

    /// Caller holds the lock. Returns the next receive's generation while the
    /// run stays open; its callbacks are delivered before that receive starts.
    private func handleReceive(
        _ result: Result<StreamingWebSocketMessage, Error>, _ active: GladiaLiveRun,
        _ effects: inout GladiaLiveEffects
    ) -> UInt64? {
        switch result {
        case .failure:
            // `end_session` closes the run before Gladia's closing handshake
            // can reach it, so any failure still found here is premature. The
            // transport error itself may carry the tokenised URL; it is dropped.
            fail(GladiaStreamingError.connectionLost, active, &effects)
            return nil
        case .success(let message):
            if let event = GladiaLiveProtocol.event(from: message) { handle(event, active, &effects) }
            guard isCurrent(active) else { return nil }
            active.receiveGeneration &+= 1
            active.receiveCallActive = true
            return active.receiveGeneration
        }
    }

    private func handle(_ event: GladiaLiveEvent, _ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        switch event {
        case .sessionStarted:
            active.sessionStarted = true
        case .transcript(let utteranceID, let text, let isFinal):
            deliver(text, utteranceID: utteranceID, isFinal: isFinal, active, &effects)
        case .sessionEnded:
            // The authoritative terminal event, valid only once `stop_recording`
            // was handed to the socket; earlier, Gladia ended the session with
            // the recording still going, which the host must hear about.
            if active.stopHandedOff {
                log("Gladia live session completed")
                close(active, &effects)
            } else {
                fail(GladiaStreamingError.unexpectedSessionEnd, active, &effects)
            }
        case .failure(let message):
            fail(GladiaStreamingError.server(message: message), active, &effects)
        }
    }

    /// Partials are drafts for their utterance; a final folds once per
    /// utterance ID and is delivered live, including during a finish. The
    /// finish then returns the same confirmed whole, so nothing is doubled.
    /// The run counts each callback until it returns, so a failure decided
    /// meanwhile on another thread is reported after it, never before.
    private func deliver(
        _ text: String, utteranceID: String?, isFinal: Bool, _ active: GladiaLiveRun,
        _ effects: inout GladiaLiveEffects
    ) {
        guard !text.isEmpty else { return }
        if isFinal {
            if let utteranceID { active.finalUtteranceIDs.insert(utteranceID) }
            let before = active.accumulator.text
            guard active.accumulator.append(final: text, eventID: utteranceID) != before else { return }
        } else if let utteranceID, active.finalUtteranceIDs.contains(utteranceID) {
            return
        }
        let callback = active.onTranscript
        active.transcriptCallbacksInFlight += 1
        effects.append { [self] in
            callback?(text, isFinal)
            transcriptCallbackReturned(active)
        }
    }
}
