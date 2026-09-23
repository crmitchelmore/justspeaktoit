import Foundation

extension GladiaLiveClient {
    /// Admission is synchronous and bounded by bytes and by chunk count across
    /// everything the run holds: audio queued while the session is requested
    /// and the socket opens, queued audio and the chunk in flight. Admitted
    /// chunks keep their bytes and capture order. Exceeding either bound ends
    /// the run with an error rather than quietly dropping speech. Audio before
    /// `start()`, after a finish began or after the run ended is not accepted.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        perform { effects in
            let active = run
            guard active.isLive, !active.finishing else { return }
            guard audioData.count.isMultiple(of: 2) else {
                fail(GladiaStreamingError.invalidPCM, active, &effects)
                return
            }
            guard active.admittedAudioChunks < Self.maximumQueuedChunks,
                  active.admittedAudioBytes + audioData.count <= active.maximumAudioBytes else {
                // Before the socket opens the budget is spent waiting for
                // Gladia; afterwards the socket stopped taking audio.
                fail(active.stage == .open ? stalledError : GladiaStreamingError.sessionNotReady, active, &effects)
                return
            }
            active.admittedAudioBytes += audioData.count
            active.admittedAudioChunks += 1
            active.admittedAnyAudio = true
            active.outgoing.append(.audio(audioData))
            startNextSend(active, &effects)
        }
    }

    /// Caller holds the lock. Hands the next outbound message to a send loop
    /// performed after the lock is released.
    func startNextSend(_ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard let send = nextSend(active) else { return }
        effects.append { [self] in sendLoop(active, send) }
    }

    /// Caller holds the lock. Exactly one send is in flight, and only once the
    /// socket's handshake completed. This only claims the next message; the
    /// send loop hands it to the socket after the lock is released.
    private func nextSend(_ active: GladiaLiveRun) -> GladiaLiveRun.PendingSend? {
        guard active.stage == .open, !active.sending, let connection = active.connection,
              let next = active.outgoing.first else { return nil }
        active.outgoing.removeFirst()
        let message: StreamingWebSocketMessage
        let stopsRecording: Bool
        switch next {
        case .audio(let pcm):
            message = .binary(pcm)
            active.inFlightAudioBytes = pcm.count
            stopsRecording = false
        case .stopRecording:
            message = .text(GladiaLiveProtocol.stopRecordingJSON)
            active.inFlightAudioBytes = 0
            stopsRecording = true
        }
        active.sending = true
        active.sendCallActive = true
        active.sendGeneration &+= 1
        return GladiaLiveRun.PendingSend(
            connection: connection, message: message, generation: active.sendGeneration,
            stopsRecording: stopsRecording
        )
    }

    /// Caller holds the lock. Confirms the claimed send is still its run's,
    /// immediately before `send` is invoked: `stop_recording` counts as handed
    /// off from here, and not while it only waited behind another effect.
    private func handOff(_ send: GladiaLiveRun.PendingSend, _ active: GladiaLiveRun) -> Bool {
        guard isCurrent(active), active.sending, active.sendGeneration == send.generation else { return false }
        if send.stopsRecording {
            active.stopHandedOff = true
            log("Gladia stop_recording handed to the socket")
        }
        return true
    }

    /// Outside the lock. A completion that arrives before `send` returns is
    /// parked and handled here, so a synchronously completing transport sends
    /// the whole queue from this loop instead of recursing. A send decided
    /// before its run was retired is dropped rather than handed to the socket.
    private func sendLoop(_ active: GladiaLiveRun, _ first: GladiaLiveRun.PendingSend) {
        var next: GladiaLiveRun.PendingSend? = first
        while let send = next {
            let generation = send.generation
            guard perform({ _ in handOff(send, active) }) else { return }
            send.connection.send(send.message) { [weak self, weak active] error in
                guard let self, let active else { return }
                self.sendCompleted(error, generation: generation, active)
            }
            next = perform { effects in
                guard active.sendGeneration == generation, active.sending else { return nil }
                active.sendCallActive = false
                guard let outcome = active.earlySendOutcome else { return nil }
                active.earlySendOutcome = nil
                return completeSend(outcome, active, &effects)
            }
        }
    }

    private func sendCompleted(_ error: Error?, generation: UInt64, _ active: GladiaLiveRun) {
        let next: GladiaLiveRun.PendingSend? = perform { effects in
            guard isCurrent(active), active.sending, active.sendGeneration == generation else { return nil }
            let outcome: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
            if active.sendCallActive {
                active.earlySendOutcome = outcome
                return nil
            }
            return completeSend(outcome, active, &effects)
        }
        if let next { sendLoop(active, next) }
    }

    /// Caller holds the lock. A rejected send is a failed session, never a
    /// frame to skip: nothing after it could still be a complete transcript.
    private func completeSend(
        _ outcome: Result<Void, Error>, _ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects
    ) -> GladiaLiveRun.PendingSend? {
        active.sending = false
        if active.inFlightAudioBytes > 0 {
            active.admittedAudioBytes -= active.inFlightAudioBytes
            active.admittedAudioChunks -= 1
            active.inFlightAudioBytes = 0
        }
        if case .failure = outcome {
            fail(GladiaStreamingError.connectionLost, active, &effects)
            return nil
        }
        return nextSend(active)
    }

    // MARK: - Finish

    /// Caller holds the lock. Queues `stop_recording` behind every admitted
    /// chunk and arms the one whole deadline. A run that never admitted audio
    /// has nothing to finalise and closes at once, empty.
    func beginFinish(_ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard !active.finishing else { return }
        active.finishing = true
        guard active.admittedAnyAudio else {
            close(active, &effects)
            return
        }
        active.outgoing.append(.stopRecording)
        arm(GladiaLive.finishBudget, active, &effects) { client, active, effects in
            client.fail(client.finishTimeoutError(active), active, &effects)
        }
        startNextSend(active, &effects)
    }

    /// The most specific error for a finish that ran out of budget.
    private func finishTimeoutError(_ active: GladiaLiveRun) -> Error {
        if active.stage != .open { return GladiaStreamingError.sessionNotReady }
        if !active.stopHandedOff { return stalledError }
        return GladiaStreamingError.missingCompletion
    }
}
