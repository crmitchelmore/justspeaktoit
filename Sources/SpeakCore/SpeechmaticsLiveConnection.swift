import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SpeechmaticsLiveClient {
    func connect(_ active: SpeechmaticsLiveRun) {
        guard let url = Self.webSocketURL() else { fail(StreamingClientError.invalidURL, active); return }
        guard let payload = Self.startRecognitionPayload(
            language: language, accuracyModel: accuracyModel, sampleRate: sampleRate
        ) else {
            fail(StreamingClientError.invalidURL, active)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        active.outgoing = [.startRecognition(payload)]
        active.phase = .connecting
        let connection = makeConnection(request)
        active.connection = connection
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active), !active.didOpen else { return }
                active.didOpen = true
                self.log("WebSocket handshake completed")
                self.pump(active)
            }
        }
        receive(active, connection)
    }

    private func receive(_ active: SpeechmaticsLiveRun, _ connection: any StreamingWebSocketConnection) {
        guard isCurrent(active) else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error):
                    self.handleReceiveFailure(error, active)
                case .success(let message):
                    self.parse(message, active)
                    self.receive(active, connection)
                }
            }
        }
    }

    /// A closure while finishing is the expected end of a graceful stop; a
    /// teardown race (`ENOTCONN`) is ignored the same way. Any other mid-session
    /// drop is a reported transport failure so a dropped recording is not saved
    /// as a silent success.
    private func handleReceiveFailure(_ error: Error, _ active: SpeechmaticsLiveRun) {
        if active.phase == .finishing || WebSocketErrorFilter.shouldIgnore(error) {
            close(active)
            return
        }
        fail(mapConnectionError(error), active)
    }

    func parse(_ message: StreamingWebSocketMessage, _ active: SpeechmaticsLiveRun) {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .binary(let bytes): data = bytes
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = SpeechmaticsRealtimeEvent(object: object) else { return }
        handle(event, active)
    }

    /// Only an explicit `Error` frame ends the session. An unrecognised frame —
    /// `Info`, `Warning`, or a field added upstream — decodes to `nil` in
    /// `parse` and is ignored, because it must never end a live recording.
    private func handle(_ event: SpeechmaticsRealtimeEvent, _ active: SpeechmaticsLiveRun) {
        guard isCurrent(active) else { return }
        switch event {
        case .recognitionStarted:
            active.ready = true
            if active.phase == .connecting { active.phase = .active }
            pump(active)
        case .audioAdded(let seqNo):
            active.lastAcknowledgedSeqNo = max(active.lastAcknowledgedSeqNo, seqNo)
        case .partial(let text):
            active.onTranscript?(text, false)
        case .final(let text):
            active.accumulated.append(final: text)
            active.onTranscript?(text, true)
        case .endOfTranscript:
            close(active)
        case .failure(let error):
            fail(error, active)
        }
    }

    func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("not authorised")
            || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Speechmatics")
        }
        return error
    }
}
