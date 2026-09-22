import Foundation

extension SpeechmaticsLiveClient {
    private enum Payload: Sendable { case startRecognition, audio(Int), endOfStream }

    /// Exactly one send is in flight. `StartRecognition` needs only the open
    /// socket; `AddAudio` and `EndOfStream` wait for `RecognitionStarted`, so
    /// audio queued while connecting drains in capture order once ready.
    func pump(_ active: SpeechmaticsLiveRun) {
        guard isCurrent(active), !active.sending, active.didOpen, let connection = active.connection,
              let next = active.outgoing.first else { return }
        let message: StreamingWebSocketMessage
        let payload: Payload
        switch next {
        case .startRecognition(let json):
            message = .text(json)
            payload = .startRecognition
        case .audio(let data):
            guard active.ready else { return }
            message = .binary(data)
            payload = .audio(data.count)
            // Counted at hand-off, exactly as the tail's `last_seq_no` expects.
            active.sentAudioFrameCount += 1
        case .endOfStream:
            guard active.ready else { return }
            let lastSeqNo = Self.endOfStreamLastSequenceNumber(
                lastAcknowledged: active.lastAcknowledgedSeqNo, sentFrameCount: active.sentAudioFrameCount
            )
            guard let json = Self.endOfStreamPayload(lastSeqNo: lastSeqNo) else {
                active.outgoing.removeFirst()
                close(active)
                return
            }
            message = .text(json)
            payload = .endOfStream
        }
        active.outgoing.removeFirst()
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        connection.send(message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized { self.completeSend(error, payload: payload, sendID: sendID, active: active) }
        }
        after(Self.sendDeadline, active) { client, active in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active) }
        }
    }

    private func completeSend(_ error: Error?, payload: Payload, sendID: UInt64, active: SpeechmaticsLiveRun) {
        guard isCurrent(active), active.sending, active.sendID == sendID else { return }
        active.sending = false
        if case .audio(let bytes) = payload { active.budget.release(bytes) }
        if let error, !WebSocketErrorFilter.shouldIgnore(error) {
            // A failed `AddAudio` or `EndOfStream` send is reported, never
            // absorbed and then presented as a successful finalisation.
            fail(mapConnectionError(error), active)
            return
        }
        if case .endOfStream = payload { active.endOfStreamSent = true }
        pump(active)
    }

    /// Commits the held capture and closes the stream. Draining, the padded tail
    /// and `EndOfStream` are bounded by scheduled deadlines rather than a
    /// readiness sleep, so a finish never blocks the caller's actor.
    ///
    /// A short recording finished during an ordinary handshake used to lose
    /// everything the user said. The queued capture is sent when readiness
    /// arrives inside the budget; a session that cannot become ready is still
    /// closed with its best available transcript, because `EndOfStream` on an
    /// unstarted session would be rejected.
    func beginFinish(_ active: SpeechmaticsLiveRun) {
        guard isCurrent(active), active.connection != nil else { close(active); return }
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        flushOutboundTail(active)
        active.outgoing.append(.endOfStream)
        pump(active)
        if !active.ready {
            after(Self.finishReadyBudget, active) { client, active in
                if !active.ready { client.close(active) }
            }
        }
        after(Self.finishBudget, active) { client, active in client.close(active) }
    }

    /// Enqueues whatever is left in the framing buffer as the stream's final
    /// frame, padded to the minimum so a short tail still reaches the service.
    private func flushOutboundTail(_ active: SpeechmaticsLiveRun) {
        let tail = active.outboundBuffer
        active.outboundBuffer.removeAll(keepingCapacity: false)
        guard !tail.isEmpty else { return }
        let padded = Self.paddedFinalChunk(tail)
        // The tail's own bytes were admitted when their chunks arrived; only the
        // padding is new, so it shares the same bounded budget.
        let delta = padded.count - tail.count
        guard delta == 0 || active.budget.admit(delta) else {
            fail(stalledError, active)
            return
        }
        active.outgoing.append(.audio(padded))
    }
}
