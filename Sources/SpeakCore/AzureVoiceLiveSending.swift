import Foundation

extension AzureVoiceLiveClient {
    /// Admission is synchronous and bounded: at most five seconds of PCM and
    /// `maximumQueuedFrames` frames may be queued or in flight. Nothing is
    /// dropped quietly: a frame that is not whole 16-bit samples, or one that
    /// would exceed a bound because the transport has stopped keeping up, fails
    /// the session visibly and keeps the text received so far.
    func admit(_ pcm: Data, _ active: AzureVoiceLiveRun) {
        guard pcm.count.isMultiple(of: AzureVoiceLiveProtocol.bytesPerSample) else {
            fail(AzureVoiceLiveError.invalidPCM, active)
            return
        }
        let frames = active.queuedAudioFrames + (active.inFlightAudioBytes > 0 ? 1 : 0) + 1
        let bytes = active.queuedAudioBytes + active.inFlightAudioBytes + pcm.count
        guard frames <= Self.maximumQueuedFrames, bytes <= maximumQueuedBytes else {
            log("Audio bound exceeded")
            fail(stalledError, active)
            return
        }
        active.outgoing.append(.audio(pcm))
        active.queuedAudioBytes += pcm.count
        active.queuedAudioFrames += 1
        active.admittedAudioBytes += pcm.count
        pump(active)
    }

    /// Exactly one send is in flight, in queue order. Nothing leaves before the
    /// transport's handshake; the configuration needs only that, while audio,
    /// the commit and the barrier wait for Azure to acknowledge it.
    func pump(_ active: AzureVoiceLiveRun) {
        guard isCurrent(active), active.didOpen, !active.sending, let connection = active.connection,
              let next = active.outgoing.first else { return }
        let message: String
        var audioBytes = 0
        switch next {
        case .sessionUpdate(let json):
            message = json
            active.sessionUpdateSent = true
        case .audio(let pcm):
            guard active.ready else { return }
            message = AzureVoiceLiveProtocol.appendJSON(pcm16: pcm)
            audioBytes = pcm.count
            active.queuedAudioBytes -= pcm.count
            active.queuedAudioFrames -= 1
        case .commit:
            guard active.ready else { return }
            message = AzureVoiceLiveProtocol.commitJSON(eventID: active.commitEventID)
            active.commitSent = true
        case .barrier:
            guard active.ready else { return }
            message = AzureVoiceLiveProtocol.barrierJSON(eventID: active.barrierEventID)
            active.barrierSent = true
        }
        active.outgoing.removeFirst()
        active.sending = true
        active.inFlightAudioBytes = audioBytes
        active.sendID &+= 1
        let sendID = active.sendID
        connection.send(.text(message)) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized { self.completeSend(error, sendID: sendID, active) }
        }
        after(Self.sendDeadline, active) { client, active in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active) }
        }
    }

    private func completeSend(_ error: Error?, sendID: UInt64, _ active: AzureVoiceLiveRun) {
        guard isCurrent(active), active.sending, active.sendID == sendID else { return }
        active.sending = false
        active.inFlightAudioBytes = 0
        if let error {
            fail(error, active)
            return
        }
        pump(active)
    }

    /// Stop sequencing: every admitted frame leaves first, then the commit for
    /// audio server VAD has not committed, then the barrier. The finish ends
    /// once the commit and the barrier are acknowledged and every item they
    /// announced has settled. One deadline bounds the whole finish, including
    /// a session that is still being configured. A session that admitted no
    /// audio has nothing to transcribe and ends at once, without a round trip.
    func beginFinish(_ active: AzureVoiceLiveRun) {
        guard active.phase == .connecting || active.phase == .active else { return }
        guard active.admittedAudioBytes > 0 || !active.transcript.isEmpty else {
            complete(active)
            return
        }
        active.phase = .finishing
        if active.admittedAudioBytes > 0 {
            active.outgoing.append(.commit)
        } else {
            active.commitAcknowledged = true
        }
        active.outgoing.append(.barrier)
        after(finishBudget, active) { client, active in
            guard active.phase == .finishing else { return }
            client.fail(client.finishTimeoutError(active), active)
        }
        if !active.ready {
            after(Self.finishReadyBudget, active) { client, active in
                if !active.ready { client.fail(AzureVoiceLiveError.sessionNotReady, active) }
            }
        }
        pump(active)
    }

    /// Why the finish budget elapsed: no session, a transport that stopped
    /// taking frames, or Azure not finishing the transcript in time.
    private func finishTimeoutError(_ active: AzureVoiceLiveRun) -> Error {
        if !active.ready { return AzureVoiceLiveError.sessionNotReady }
        if !active.isDrained { return stalledError }
        return AzureSpeechError.timedOut
    }
}
