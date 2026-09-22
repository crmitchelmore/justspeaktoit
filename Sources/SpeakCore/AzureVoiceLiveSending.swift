import Foundation

/// Audio offered before the first `start()` and why any of it could not be held.
struct AzureVoiceLiveHeldAudio {
    let audio: [Data]
    let failure: AzureVoiceLiveError?
}

extension AzureVoiceLiveClient {
    /// Admission is synchronous and bounded in every phase: at most five
    /// seconds of PCM and `maximumQueuedFrames` frames may be queued or in
    /// flight. Nothing is dropped quietly. A frame that is not whole 16-bit
    /// samples, or that would exceed a bound, fails the session visibly; before
    /// `start()` the failure is held and reported when the session starts.
    /// A detached, finishing or closed run takes no more input: the finish has
    /// already sealed the committed audio, and hosts stop capture before it.
    func admit(_ pcm: Data, _ effects: inout AzureVoiceLiveEffects) {
        let active = run
        switch active.phase {
        case .idle:
            hold(pcm)
        case .connecting, .active:
            guard pcm.count.isMultiple(of: AzureVoiceLiveProtocol.bytesPerSample) else {
                fail(AzureVoiceLiveError.invalidPCM, active, &effects)
                return
            }
            guard fits(pcm.count, active) else {
                log("Audio bound exceeded")
                fail(AzureVoiceLiveError.audioOverflow, active, &effects)
                return
            }
            enqueueAudio(pcm, active)
            pump(active, &effects)
        case .detached, .finishing, .closed:
            break
        }
    }

    private func fits(_ byteCount: Int, _ active: AzureVoiceLiveRun) -> Bool {
        let frames = active.queuedAudioFrames + (active.inFlightAudioBytes > 0 ? 1 : 0) + 1
        let bytes = active.queuedAudioBytes + active.inFlightAudioBytes + byteCount
        return frames <= Self.maximumQueuedFrames && bytes <= Self.maximumQueuedBytes
    }

    private func hold(_ pcm: Data) {
        guard heldFailure == nil else { return }
        guard pcm.count.isMultiple(of: AzureVoiceLiveProtocol.bytesPerSample) else {
            heldFailure = .invalidPCM
            return
        }
        let held = preroll.snapshot
        let byteLimit = min(Self.maximumQueuedBytes, preroll.maximumByteCount)
        guard held.chunkCount < Self.maximumQueuedFrames, held.byteCount + pcm.count <= byteLimit else {
            heldFailure = .audioOverflow
            return
        }
        preroll.append(pcm)
    }

    func takeHeldAudio() -> AzureVoiceLiveHeldAudio {
        let held = AzureVoiceLiveHeldAudio(audio: preroll.drain(), failure: heldFailure)
        heldFailure = nil
        return held
    }

    func discardHeldAudio() {
        preroll.reset()
        heldFailure = nil
    }

    func enqueueAudio(_ pcm: Data, _ active: AzureVoiceLiveRun) {
        active.outgoing.append(.audio(pcm))
        active.queuedAudioBytes += pcm.count
        active.queuedAudioFrames += 1
        active.admittedAudioBytes += pcm.count
    }

    /// Exactly one send is in flight, in queue order. Nothing leaves before the
    /// transport's handshake; the configuration needs only that, while audio
    /// and controls wait for Azure to acknowledge it.
    func pump(_ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        guard isCurrent(active), active.didOpen, !active.sending, let connection = active.connection,
              let next = active.outgoing.first else { return }
        switch next {
        case .sessionUpdate:
            active.sessionUpdateSent = true
        case .audio(let pcm):
            guard active.ready else { return }
            active.queuedAudioBytes -= pcm.count
            active.queuedAudioFrames -= 1
            active.inFlightAudioBytes = pcm.count
        case .commit:
            guard active.ready else { return }
            active.finalCommitSent = true
        case .barrier:
            guard active.ready else { return }
            active.barrierSent = true
        }
        active.outgoing.removeFirst()
        active.sending = true
        active.sendID &+= 1
        let sendID = active.sendID
        effects.append {
            // Encoded here, outside the lock, for the one frame in flight.
            connection.send(.text(next.wireText)) { [weak self, weak active] error in
                guard let self, let active else { return }
                self.transact { effects in self.completeSend(error, sendID: sendID, active, &effects) }
            }
        }
        watchSend(active, &effects)
    }

    private func completeSend(
        _ error: Error?, sendID: UInt64, _ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects
    ) {
        guard isCurrent(active), active.sending, active.sendID == sendID else { return }
        active.sending = false
        active.inFlightAudioBytes = 0
        if let error {
            fail(error, active, &effects)
            return
        }
        pump(active, &effects)
    }

    /// One stall watchdog per run rather than a timer per frame. It is armed
    /// for the send in flight; when it fires after that send completed, it
    /// re-arms for whichever send is then in flight.
    private func watchSend(_ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        guard active.watchedSendID == nil else { return }
        active.watchedSendID = active.sendID
        after(Self.sendDeadline, active, &effects) { client, active, effects in
            let watched = active.watchedSendID
            active.watchedSendID = nil
            guard active.sending else { return }
            if active.sendID == watched {
                client.fail(client.stalledError, active, &effects)
            } else {
                client.watchSend(active, &effects)
            }
        }
    }

    /// A finish caller joins the run it observed when it called.
    func join(
        _ active: AzureVoiceLiveRun, _ continuation: CheckedContinuation<String?, Never>,
        _ effects: inout AzureVoiceLiveEffects
    ) {
        if Task.isCancelled, isCurrent(active) { close(active, &effects) }
        switch active.phase {
        case .closed:
            // Queued behind any delivery still pending for this run, such as its error.
            deliveries.append(.finish(continuation, active.transcript.confirmedOrNil))
        case .idle:
            discardHeldAudio()
            close(active, &effects)
            deliveries.append(.finish(continuation, nil))
        case .detached:
            active.waiters.append(continuation)
            complete(active, &effects)
        case .connecting, .active, .finishing:
            active.waiters.append(continuation)
            beginFinish(active, &effects)
        }
    }

    /// Stop sequencing: every admitted frame leaves first, then the commit for
    /// audio server VAD has not committed, then the barrier. The finish ends as
    /// soon as the barrier is acknowledged and every item it proves announced
    /// has settled. One deadline bounds the whole finish, including a session
    /// that is still connecting. A session that admitted no audio has nothing
    /// to transcribe and ends at once, without a round trip.
    func beginFinish(_ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        guard active.phase == .connecting || active.phase == .active else { return }
        guard active.admittedAudioBytes > 0 || !active.transcript.isEmpty else {
            close(active, &effects)
            return
        }
        active.phase = .finishing
        if active.admittedAudioBytes > 0 { active.outgoing.append(.commit(eventID: active.commitEventID)) }
        active.outgoing.append(.barrier(eventID: active.barrierEventID))
        // Armed before anything is sent, so the budget covers the whole finish.
        after(finishBudget, active, &effects) { client, active, effects in
            guard active.phase == .finishing else { return }
            client.fail(client.finishTimeoutError(active), active, &effects)
        }
        pump(active, &effects)
    }

    private func finishTimeoutError(_ active: AzureVoiceLiveRun) -> Error {
        if !active.ready { return AzureVoiceLiveError.sessionNotReady }
        if !active.isDrained { return stalledError }
        return AzureVoiceLiveError.missingFinalTranscript
    }

    func settleIfDone(_ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        guard isCurrent(active), active.phase == .finishing, active.barrierSettled,
              active.transcript.allSettled else { return }
        complete(active, &effects)
    }

    /// Ends a settled finish. Silence returns nothing; a recording in which
    /// every attempted turn failed is reported before the finish returns.
    func complete(_ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        if active.transcript.confirmedOrNil == nil, active.transcript.hasFailedItem {
            fail(AzureSpeechError.transcriptionFailed, active, &effects)
        } else {
            close(active, &effects)
        }
    }
}
