import Foundation

// MARK: - Sending

extension RevAILiveClient {
    private struct PendingSend {
        let connection: any StreamingWebSocketConnection
        let item: RevAILiveRun.Outbound
        let sendID: UInt64
    }

    /// How long a failed send waits for the receive side to report why the
    /// stream ended. A failing send usually shares its cause with the receive,
    /// which reports the peer's close code after the messages the transport
    /// already holds, so its report names the cause and keeps trailing finals.
    /// The grace only bounds a send failure the receive never reflects.
    static let sendFailureGrace: TimeInterval = 1

    /// Starts the send loop when it could move something and nothing else
    /// will: an in-flight send, a running loop and `connected` each request it
    /// themselves.
    func requestPump(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard active.isReady, !active.sending, !active.pumping, active.sendFailure == nil,
              active.connection != nil, !active.outgoing.isEmpty else { return }
        effects.append { self.pump(active) }
    }

    /// Exactly one send is in flight, in queue order. The loop owns the queue
    /// until nothing more can move; a completion that arrives while it runs,
    /// synchronously or on another thread, only clears `sending`, and the loop
    /// sends the next frame. No lock is held across a transport call.
    func pump(_ active: RevAILiveRun) {
        let owner: Bool = lock.withLock {
            guard isCurrent(active), !active.pumping else { return false }
            active.pumping = true
            return true
        }
        guard owner else { return }
        while let next = lock.withLock({ () -> PendingSend? in nextSend(active) }) {
            transmit(next, active)
        }
    }

    /// Takes the next frame, or releases the loop in the same critical section
    /// that found nothing to send, so no newly queued work is stranded.
    private func nextSend(_ active: RevAILiveRun) -> PendingSend? {
        guard isCurrent(active), !active.sending, active.isReady, active.sendFailure == nil,
              let connection = active.connection, !active.outgoing.isEmpty else {
            active.pumping = false
            return nil
        }
        let item = active.takeNext()
        return PendingSend(connection: connection, item: item, sendID: active.sendID)
    }

    private func transmit(_ next: PendingSend, _ active: RevAILiveRun) {
        let message: StreamingWebSocketMessage
        let sent: RevAILiveRun.Sent
        switch next.item {
        case .audio(let pcm):
            message = .binary(pcm)
            sent = .audio(bytes: pcm.count)
        case .endOfStream:
            message = .text(Self.endOfStreamToken)
            sent = .endOfStream
        }
        let sendID = next.sendID
        after(Self.sendDeadline, active) { client, active, effects in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active, &effects) }
        }
        next.connection.send(message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.completeSend(error, sent, sendID: sendID, active)
        }
    }

    private func completeSend(_ error: Error?, _ sent: RevAILiveRun.Sent, sendID: UInt64, _ active: RevAILiveRun) {
        withState { effects in
            guard isCurrent(active), active.sending, active.sendID == sendID else { return }
            active.sending = false
            switch sent {
            case .audio(let bytes):
                active.bufferedFrames -= 1
                active.bufferedBytes -= bytes
            case .endOfStream:
                if error == nil { active.endOfStreamSent = true }
            }
            guard let error else {
                requestPump(active, &effects)
                return
            }
            // A failed drain or `EOS` is never a success, but the receive side
            // reports the cause: publish this error only if it does not.
            active.sendFailure = error
            log("Send failed")
            effects.append {
                self.after(Self.sendFailureGrace, active) { client, active, effects in
                    guard let failure = active.sendFailure else { return }
                    let closeCode = (failure as? StreamingWebSocketCloseReporting)?.webSocketCloseCode
                    client.fail(client.failure(for: failure, closeCode: closeCode, active), active, &effects)
                }
            }
        }
    }
}

// MARK: - Finalisation

extension RevAILiveClient {
    /// Stop sequencing: stop accepting audio, drain what was admitted, then
    /// send `EOS` and wait for the trailing hypothesis and the normal close. A
    /// session still connecting — including one whose transport factory has
    /// not returned yet — keeps its capture and sends it once `connected`
    /// arrives. One deadline bounds the whole finish; which step it catches
    /// decides the error. The socket-free seam, and a started session that was
    /// given no audio, have nothing to commit: their finish is the confirmed
    /// text so far.
    func beginFinish(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard active.phase != .finishing else { return }
        guard active.usesTransport, active.admittedAudioBytes > 0 else {
            close(active, &effects)
            return
        }
        active.phase = .finishing
        active.outgoing.append(.endOfStream)
        log("Finishing")
        requestPump(active, &effects)
        effects.append {
            self.after(RevAIStreaming.finishBudget, active) { client, active, effects in
                guard active.phase == .finishing else { return }
                client.fail(client.finishDeadlineError(active), active, &effects)
            }
        }
    }

    func finishDeadlineError(_ active: RevAILiveRun) -> Error {
        if !active.isReady { return RevAILiveError.sessionNotReady }
        if active.endOfStreamSent { return RevAILiveError.missingCompletion }
        return stalledError
    }
}
