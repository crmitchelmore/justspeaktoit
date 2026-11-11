import Foundation

extension OpenAIRealtimeLiveClient {
    /// Admission is synchronous and bounded: at most five seconds of PCM may be
    /// queued or in flight and at most `maximumQueuedFrames` frames may wait.
    /// Exceeding either is reported exactly once; later frames are dropped so
    /// the admitted prefix stays contiguous and can still be finalised.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            guard active.phase == .connecting || active.phase == .active else { return }
            guard audioData.count.isMultiple(of: OpenAIRealtimeProtocol.bytesPerSample) else {
                fail(OpenAIRealtimeStreamingError.invalidPCM, active)
                return
            }
            guard !active.overflowReported else { return }
            let oldReservation = OpenAIRealtimeLiveRun.turnReservation(bytesSinceCommit: active.audioBytesSinceCommit)
            let turnBytes = min(
                OpenAIRealtimeProtocol.minimumCommitBytes,
                active.audioBytesSinceCommit + min(audioData.count, OpenAIRealtimeProtocol.minimumCommitBytes)
            )
            let reservation = OpenAIRealtimeLiveRun.turnReservation(bytesSinceCommit: turnBytes)
            let additionalBytes = audioData.count + reservation.bytes - oldReservation.bytes
            let frames = active.queuedAudioFrames + (active.sending ? 1 : 0) + 1 + reservation.frames
            guard frames <= Self.maximumQueuedFrames,
                  active.budget.admit(additionalBytes) else {
                active.overflowReported = true
                log("Audio budget exceeded; further audio is dropped")
                active.onError?(OpenAIRealtimeStreamingError.audioOverflow)
                return
            }
            active.outgoing.append(.audio(audioData))
            active.queuedAudioBytes += audioData.count
            active.queuedAudioFrames += 1
            active.audioBytesSinceCommit = turnBytes
            pump(active)
        }
    }

    private enum Payload: Sendable { case sessionUpdate, audio(Int), commit(UInt64) }

    /// Exactly one send is in flight. `session.update` needs only the open
    /// socket; audio and commit wait for the acknowledged configuration.
    func pump(_ active: OpenAIRealtimeLiveRun) {
        guard isCurrent(active), !active.sending, active.didOpen, let connection = active.connection,
              let next = active.outgoing.first else { return }
        let message: String
        let payload: Payload
        switch next {
        case .sessionUpdate(let json):
            message = json
            payload = .sessionUpdate
            active.sessionUpdateSent = true
        case .audio(let pcm):
            guard active.ready else { return }
            message = OpenAIRealtimeProtocol.appendJSON(pcm16: pcm)
            payload = .audio(pcm.count)
            active.queuedAudioBytes -= pcm.count
            active.queuedAudioFrames -= 1
        case .commit(let sequence):
            guard active.ready else { return }
            message = OpenAIRealtimeProtocol.commitJSON(eventID: active.eventID(forCommit: sequence))
            payload = .commit(sequence)
            active.commitsAwaitingAck.append(sequence)
        }
        active.outgoing.removeFirst()
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        connection.send(.text(message)) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized { self.completeSend(error, payload: payload, sendID: sendID, active: active) }
        }
        after(Self.sendDeadline, active) { client, active in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active) }
        }
    }

    private func completeSend(_ error: Error?, payload: Payload, sendID: UInt64, active: OpenAIRealtimeLiveRun) {
        guard isCurrent(active), active.sending, active.sendID == sendID else { return }
        active.sending = false
        if case .audio(let bytes) = payload { active.budget.release(bytes) }
        if let error { fail(error, active); return }
        if case .commit(let sequence) = payload {
            active.sentCommits.insert(sequence)
            if active.phase == .finishing, active.finalCommitSequence == sequence {
                if active.finishIsSettled { close(active); return }
                scheduleFinalizeDeadline(active)
            }
        }
        if active.isDrained { active.resolveAllDrainWaiters() }
        pump(active)
    }

    /// Queues a commit for audio admitted since the previous one. Returns
    /// `false`, sending nothing, when there is nothing to commit.
    func enqueueCommit(_ active: OpenAIRealtimeLiveRun) -> Bool {
        guard active.audioBytesSinceCommit > 0 else { return false }
        let shortfall = OpenAIRealtimeProtocol.minimumCommitBytes - active.audioBytesSinceCommit
        if shortfall > 0 {
            // Documented, bounded padding: the server rejects commits under
            // 100 ms, so a shorter tail is completed with silence.
            let padding = Data(count: shortfall)
            // Admission already reserved these bytes and this frame slot.
            active.outgoing.append(.audio(padding))
            active.queuedAudioBytes += padding.count
            active.queuedAudioFrames += 1
        }
        active.commitSequence += 1
        active.lastCommitSequence = active.commitSequence
        active.outgoing.append(.commit(active.commitSequence))
        active.audioBytesSinceCommit = 0
        return true
    }

    /// Stop sequencing: drain admitted PCM, pad and commit, then wait for the
    /// committed item's completion. No admitted audio means an empty result
    /// with no commit and no server error. Readiness, drain and completion
    /// each have a bounded deadline so a finish can never hang.
    func beginFinish(_ active: OpenAIRealtimeLiveRun, deliverCallbacks: Bool) {
        guard isCurrent(active), active.connection != nil else { close(active); return }
        if !deliverCallbacks { active.deliverWhileFinishing = false }
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        active.deliverWhileFinishing = deliverCallbacks
        _ = enqueueCommit(active)
        active.finalCommitSequence = active.lastCommitSequence
        guard active.finalCommitSequence != nil else { close(active); return }
        if active.finalCommitSent {
            if active.finishIsSettled { close(active); return }
            scheduleFinalizeDeadline(active)
        }
        pump(active)
        if !active.ready {
            after(Self.finishReadyBudget, active) { client, active in
                if !active.ready { client.fail(OpenAIRealtimeStreamingError.sessionNotReady, active) }
            }
        }
        after(Self.finishDeadline, active) { client, active in
            if active.finalCommitSent { client.close(active) } else { client.fail(client.stalledError, active) }
        }
    }

    /// Once the commit has left, the completed event is expected within the
    /// model's finalise budget; the best available text is returned either way.
    private func scheduleFinalizeDeadline(_ active: OpenAIRealtimeLiveRun) {
        guard !active.finalizeDeadlineScheduled else { return }
        active.finalizeDeadlineScheduled = true
        after(finalizeBudget, active) { client, active in
            if active.phase == .finishing { client.close(active) }
        }
    }
}
