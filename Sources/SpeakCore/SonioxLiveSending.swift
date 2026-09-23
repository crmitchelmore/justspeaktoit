import Foundation

extension SonioxLiveClient {

    private enum Payload: Sendable { case config, audio(Int), endOfStream }

    /// Exactly one send is in flight. The configuration frame needs only the
    /// open socket; audio and the end-of-stream frame follow behind it.
    func pump(_ active: SonioxLiveRun) {
        guard isCurrent(active), !active.sending, active.didOpen,
              let connection = active.connection, let next = active.outgoing.first else { return }
        let message: StreamingWebSocketMessage
        let payload: Payload
        switch next {
        case .config(let json):
            message = .text(json)
            payload = .config
        case .audio(let data):
            guard active.configSent else { return }
            message = .binary(data)
            payload = .audio(data.count)
            active.queuedAudioBytes -= data.count
            active.queuedAudioFrames -= 1
        case .endOfStream:
            guard active.configSent else { return }
            message = .binary(Data())
            payload = .endOfStream
            // The receive callback may run before the send completion. Mark
            // hand-off now; `finished` remains the success authority.
            active.endOfStreamSent = true
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

    private func completeSend(_ error: Error?, payload: Payload, sendID: UInt64, active: SonioxLiveRun) {
        guard isCurrent(active), active.sending, active.sendID == sendID else { return }
        active.sending = false
        if case .audio(let bytes) = payload { active.budget.release(bytes) }
        if let error {
            fail(error, active)
            return
        }
        switch payload {
        case .config: active.configSent = true
        case .audio: break
        case .endOfStream: break
        }
        pump(active)
    }
}
