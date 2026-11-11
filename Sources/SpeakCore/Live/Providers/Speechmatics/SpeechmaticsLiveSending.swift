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
        case .endOfStream:
            guard active.ready else { return }
            // Every audio frame ahead of this one has completed, so the count is
            // final; the server's acknowledgements are its floor.
            let lastSeqNo = Self.endOfStreamLastSequenceNumber(
                lastAcknowledged: active.lastAcknowledgedSeqNo, sentFrameCount: active.sentAudioFrameCount
            )
            message = .text(Self.endOfStreamPayload(lastSeqNo: lastSeqNo))
            payload = .endOfStream
            // From here the server's `EndOfTranscript` is the authoritative
            // answer, even if it lands before this send's completion callback.
            active.endOfStreamHandedOff = true
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
        if let error {
            // A rejected `StartRecognition`, `AddAudio` or `EndOfStream` is a
            // failed session, never a frame to skip: the service did not receive
            // it, so nothing after it could be a successful finalisation. A
            // teardown-shaped `ENOTCONN` is no exception while the run is still
            // current; a late one after `EndOfTranscript` finds the run closed.
            fail(mapConnectionError(error), active)
            return
        }
        // Only a frame the transport confirmed counts towards `last_seq_no`.
        if case .audio = payload { active.sentAudioFrameCount += 1 }
        pump(active)
    }

    /// Commits the held capture and closes the stream. Draining, the padded tail
    /// and `EndOfStream` are bounded by scheduled deadlines rather than a
    /// readiness sleep, so a finish never blocks the caller's actor.
    ///
    /// A short recording finished during an ordinary handshake used to lose
    /// everything the user said; the queued capture is now sent when readiness
    /// arrives inside the budget. A session that cannot become ready, drain, or
    /// receive `EndOfTranscript` inside the budget fails with a provider error
    /// while keeping the text received so far: `EndOfStream` on an unstarted
    /// session would be rejected, and a missing `EndOfTranscript` means the
    /// tail may never have been transcribed, so neither is a success.
    func beginFinish(_ active: SpeechmaticsLiveRun) {
        guard isCurrent(active), active.connection != nil else { close(active); return }
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        flushOutboundTail(active)
        active.outgoing.append(.endOfStream)
        pump(active)
        if !active.ready {
            after(Self.finishReadyBudget, active) { client, active in
                if !active.ready { client.fail(SpeechmaticsRealtimeError.recognitionNotStarted, active) }
            }
        }
        // One deadline, armed here, bounds readiness, the audio drain,
        // `EndOfStream` and `EndOfTranscript` together; the finish never waits
        // longer than this budget whatever stage it stalls in.
        after(Self.finishBudget, active) { client, active in
            client.fail(client.finishTimeoutError(active), active)
        }
    }

    /// The most specific provider error for a finish that ran out of budget.
    private func finishTimeoutError(_ active: SpeechmaticsLiveRun) -> Error {
        if !active.ready { return SpeechmaticsRealtimeError.recognitionNotStarted }
        if !active.endOfStreamHandedOff { return stalledError }
        return SpeechmaticsRealtimeError.transcriptNotFinalised
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
