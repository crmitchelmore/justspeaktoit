import Foundation

extension XAISpeechToTextLiveClient {
    /// Exactly one send is in flight, and nothing moves before
    /// `transcript.created`: audio sent earlier is refused by the service, so
    /// it waits in the queue. Once the queue is empty a finishing run sends
    /// `audio.done`, the one control frame of the protocol.
    func pump(_ active: XAISpeechToTextLiveRun) {
        guard isCurrent(active), active.ready, !active.sending, let connection = active.connection else { return }
        let message: StreamingWebSocketMessage
        let audioBytes: Int
        if !active.outgoing.isEmpty {
            let data = active.outgoing.removeFirst()
            message = .binary(data)
            audioBytes = data.count
        } else if active.phase == .finishing, !active.audioDoneSent {
            active.audioDoneSent = true
            message = .text(Self.audioDoneFrame)
            audioBytes = 0
        } else { return }
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        connection.send(message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized { self.completeSend(error, audioBytes: audioBytes, sendID: sendID, active: active) }
        }
        after(Self.sendDeadline, active) { client, active in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active) }
        }
    }

    private func completeSend(_ error: Error?, audioBytes: Int, sendID: UInt64, active: XAISpeechToTextLiveRun) {
        guard isCurrent(active), active.sending, active.sendID == sendID else { return }
        active.sending = false
        active.budget.release(audioBytes)
        if let error {
            // The server closes the socket after `transcript.done`, so a send
            // that lands on that closure is not a failure.
            if active.doneReceived { close(active) } else { fail(mapConnectionError(error), active) }
            return
        }
        pump(active)
    }

    /// Stop sequencing: drain admitted PCM, send `audio.done`, then wait for
    /// `transcript.done`. xAI requires `transcript.created` before audio, so a
    /// short recording finished during an ordinary handshake holds its capture
    /// until the session is ready rather than pushing PCM the service would
    /// refuse. A session that cannot become ready inside `readyBudget` fails
    /// visibly, and one deadline bounds the whole finish: only
    /// `transcript.done` completes it, so a drain that stalls or a completion
    /// that never arrives is reported, with the locked spans received so far
    /// returned for recovery rather than presented as a finished transcript.
    func beginFinish(_ active: XAISpeechToTextLiveRun) {
        guard isCurrent(active), active.connection != nil, !active.doneReceived else { close(active); return }
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        pump(active)
        if !active.ready {
            after(Self.readyBudget, active) { client, active in
                if !active.ready { client.fail(XAISpeechToTextError.sessionNotReady, active) }
            }
        }
        after(Self.finishBudget, active) { client, active in
            if active.audioDoneSent, !active.sending {
                client.fail(XAISpeechToTextError.missingCompletion, active)
            } else {
                client.fail(client.stalledError, active)
            }
        }
    }
}
