import Foundation

extension OpenAIRealtimeLiveClient {
    private enum Payload: Sendable { case sessionUpdate, audio(Int), commit }

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
        case .commit:
            guard active.ready else { return }
            message = OpenAIRealtimeProtocol.commitJSON
            payload = .commit
            active.commitState = .inFlight
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
        if case .commit = payload {
            active.commitState = .sent
            if active.phase == .finishing { scheduleFinalizeDeadline(active) }
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
            _ = active.budget.admit(padding.count)
            active.outgoing.append(.audio(padding))
            active.queuedAudioBytes += padding.count
            active.queuedAudioFrames += 1
        }
        active.outgoing.append(.commit)
        active.audioBytesSinceCommit = 0
        active.commitState = .queued
        active.expectedItemKey = nil
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
        active.completedBeforeFinish = active.assembler.completedItemKeys
        _ = enqueueCommit(active)
        guard active.commitState != .none else { close(active); return }
        if active.commitState == .sent {
            if let expected = active.expectedItemKey, active.assembler.completedItemKeys.contains(expected) {
                close(active)
                return
            }
            scheduleFinalizeDeadline(active)
        }
        pump(active)
        if !active.ready {
            after(Self.finishReadyBudget, active) { client, active in
                if !active.ready { client.fail(OpenAIRealtimeStreamingError.sessionNotReady, active) }
            }
        }
        after(Self.finishDeadline, active) { client, active in
            if active.commitState == .sent { client.close(active) } else { client.fail(client.stalledError, active) }
        }
    }

    /// Once the commit has left, the completed event is expected within the
    /// model's finalise budget; the best available text is returned either way.
    private func scheduleFinalizeDeadline(_ active: OpenAIRealtimeLiveRun) {
        after(finalizeBudget, active) { client, active in
            if active.phase == .finishing { client.close(active) }
        }
    }
}
