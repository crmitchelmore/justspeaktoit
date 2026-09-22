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
                    // A valid `EndOfTranscript` closes the run before any expected
                    // disconnect can reach it, so a failure that still finds the
                    // run current is always premature: the session was waiting
                    // for readiness, draining audio, or waiting for its terminal
                    // frame. That includes a teardown-shaped `ENOTCONN`. Report
                    // it and keep the accumulated text; only an explicit cancel
                    // (which closes first) silences a later closure.
                    self.fail(self.mapConnectionError(error), active)
                case .success(let message):
                    self.parse(message, active)
                    self.receive(active, connection)
                }
            }
        }
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
            // The authoritative terminal frame, valid only once our ordered
            // `EndOfStream` has been handed to the socket. Earlier, it means the
            // service ended the session while audio or the hand-off was still
            // pending, which must surface as a failure rather than leave the
            // host recording into a closed client.
            guard active.endOfStreamHandedOff else {
                fail(SpeechmaticsRealtimeError.unexpectedEndOfTranscript, active)
                return
            }
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
