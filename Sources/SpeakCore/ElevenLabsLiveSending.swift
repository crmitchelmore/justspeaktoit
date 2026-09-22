import Foundation

extension ElevenLabsLiveClient {
    /// Manual mode has no request IDs. Owning a single <=20-second segment and
    /// pausing further audio until its final makes each acknowledgement unique.
    /// https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies
    func pump(_ active: ElevenLabsLiveRun) {
        guard isCurrent(active), active.ready, !active.sending, let connection = active.connection else { return }
        if active.pendingCommit != nil {
            guard active.commitFinalReceived else { return }
            active.pendingCommit = nil
            active.commitFinalReceived = false
            active.segmentBytes = 0
        }
        guard let frame = nextFrame(active) else { return }
        let audioBytes = frame.audioBytes
        let commit = frame.commitID
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        connection.send(frame.message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active), active.sendID == sendID else { return }
                active.sending = false
                active.sendBudget.release(audioBytes)
                if let error { self.fail(error, active); return }
                if let commit, !active.commitFinalReceived {
                    self.after(Self.finishBudget, active) { client, active in
                        if active.pendingCommit == commit {
                            client.fail(ElevenLabsStreamingError.missingCompletion, active)
                        }
                    }
                }
                self.pump(active)
            }
        }
        after(Self.sendDeadline, active) { client, active in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active) }
        }
    }

    private struct Frame {
        let message: StreamingWebSocketMessage
        let audioBytes: Int
        let commitID: UInt64?
    }

    private func nextFrame(_ active: ElevenLabsLiveRun) -> Frame? {
        let limit = sampleRate * 2 * Self.segmentSeconds
        let message: StreamingWebSocketMessage
        let audioBytes: Int
        let commit: UInt64?
        if active.segmentBytes == limit || (active.phase == .finishing && active.outgoing.isEmpty) {
            guard active.segmentBytes > 0 else { close(active); return nil }
            active.commitSequence += 1
            commit = active.commitSequence
            active.pendingCommit = commit
            message = .text(ElevenLabsLiveProtocol.commitJSON())
            audioBytes = 0
        } else if !active.outgoing.isEmpty {
            let next = active.outgoing.removeFirst()
            audioBytes = min(next.count, limit - active.segmentBytes)
            let data = Data(next.prefix(audioBytes))
            if audioBytes < next.count { active.outgoing.insert(Data(next.dropFirst(audioBytes)), at: 0) }
            active.segmentBytes += audioBytes
            commit = nil
            message = .text(ElevenLabsLiveProtocol.audioChunkJSON(pcm16: data, sampleRate: sampleRate))
        } else { return nil }
        return Frame(message: message, audioBytes: audioBytes, commitID: commit)
    }
}
