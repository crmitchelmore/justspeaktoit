import Foundation

extension ElevenLabsLiveClient {
    /// One frame is in flight at a time, and nothing moves before
    /// `session_started`. The server's VAD commits segments while recording;
    /// the only client commit is the finish's, after every admitted frame.
    /// https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies
    func pump(_ active: ElevenLabsLiveRun) {
        guard isCurrent(active), active.ready, !active.sending, let connection = active.connection,
              !active.outgoing.isEmpty else { return }
        let next = active.outgoing.removeFirst()
        let message: StreamingWebSocketMessage
        let audioBytes: Int
        let isCommit: Bool
        switch next {
        case .audio(let data):
            message = .text(ElevenLabsLiveProtocol.audioChunkJSON(pcm16: data, sampleRate: sampleRate))
            audioBytes = data.count
            isCommit = false
        case .commit:
            message = .text(ElevenLabsLiveProtocol.commitJSON())
            audioBytes = 0
            isCommit = true
        }
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        connection.send(message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active), active.sendID == sendID else { return }
                active.sending = false
                active.sendBudget.release(audioBytes)
                // A spurious ENOTCONN on a send is ignored, as it always has
                // been: the receive side decides whether the socket is gone.
                if let error, !WebSocketErrorFilter.isSpuriousDisconnect(error) { self.fail(error, active); return }
                // VAD commits carry no correlation id, so no final can be
                // recognised as this commit's answer. The finish instead reads
                // finals for a bounded window once the commit is sent.
                if isCommit {
                    self.after(self.timing.postCommitDrain, active) { client, active in client.close(active) }
                }
                self.pump(active)
            }
        }
        // A finish is bounded by its own deadline, which returns what it has.
        after(Self.sendDeadline, active) { client, active in
            if active.sending, active.sendID == sendID, active.phase != .finishing {
                client.fail(client.stalledError, active)
            }
        }
    }

    /// Stop sequencing: admitted audio, then one manual commit, then the
    /// post-commit window. A finish that lands before `session_started` waits
    /// at most `finishReadyBudget` for it; one that has nothing to send closes
    /// at once. Every bound ends the finish with the text it has.
    func beginFinish(_ active: ElevenLabsLiveRun) {
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        // A session that never started has sent nothing, so without held
        // audio there is nothing to commit or to wait for.
        guard active.ready || !preroll.isEmpty else { close(active); return }
        after(timing.overall, active) { client, active in client.close(active) }
        if active.ready {
            queueCommit(active)
        } else {
            after(timing.readiness, active) { client, active in
                if !active.ready { client.close(active) }
            }
        }
    }

    /// Queues the finish's manual commit behind every admitted frame, once.
    func queueCommit(_ active: ElevenLabsLiveRun) {
        guard !active.commitQueued else { return }
        active.commitQueued = true
        active.outgoing.append(.commit)
        pump(active)
    }

    /// Bounded admission once the session has started: at most five seconds of
    /// PCM and `maximumQueuedFrames` frames may be queued or in flight.
    /// Exceeding either is a transport stall, reported once.
    func enqueueAudio(_ audio: Data, _ active: ElevenLabsLiveRun) {
        guard active.outgoing.count + (active.sending ? 1 : 0) < Self.maximumQueuedFrames,
              active.sendBudget.admit(audio.count) else {
            fail(stalledError, active)
            return
        }
        active.outgoing.append(.audio(audio))
        pump(active)
    }
}
