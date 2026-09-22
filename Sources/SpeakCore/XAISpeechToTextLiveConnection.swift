import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension XAISpeechToTextLiveClient {
    func connect(_ active: XAISpeechToTextLiveRun, request: URLRequest) {
        let connection = makeConnection(request)
        active.connection = connection
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                self.log("WebSocket handshake completed")
            }
        }
        receive(active, connection)
        // The open socket is not readiness: xAI initialises its recogniser
        // first, and only `transcript.created` permits audio.
        after(Self.readyDeadline, active) { client, active in
            if !active.ready { client.fail(XAISpeechToTextError.sessionNotReady, active) }
        }
    }

    private func receive(_ active: XAISpeechToTextLiveRun, _ connection: any StreamingWebSocketConnection) {
        guard isCurrent(active) else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error):
                    self.transportFailed(error, active)
                case .success(let message):
                    switch message {
                    case .text(let text): self.handle(Data(text.utf8), active)
                    case .binary(let data): self.handle(data, active)
                    }
                    self.receive(active, connection)
                }
            }
        }
    }

    /// The server sends `transcript.done` and only then closes the socket, so
    /// a closure is benign only after that frame. Any earlier failure, even
    /// once `audio.done` has left, ends the run visibly: the finish still
    /// returns the locked spans received so far for recovery, but the error
    /// is published first so a caller cannot mistake them for a completed
    /// transcription.
    private func transportFailed(_ error: Error, _ active: XAISpeechToTextLiveRun) {
        if active.doneReceived {
            close(active)
        } else {
            fail(mapConnectionError(error), active)
        }
    }

    /// Only an explicit `error` frame ends the session. An unrecognised frame,
    /// such as a keepalive or a field added upstream, is ignored, matching
    /// every other shared client, because it must never end a live recording.
    func handle(_ data: Data, _ active: XAISpeechToTextLiveRun) {
        guard isCurrent(active),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = XAISpeechToTextEvent(object: object) else { return }
        switch event {
        case .created:
            handleCreated(active)
        case .partial(let text, let isFinal, _, let eventID):
            handlePartial(text, isFinal: isFinal, eventID: eventID, active)
        case .done(let text):
            handleDone(text, active)
        case .failure(let message):
            fail(Self.error(fromServerMessage: message), active)
        }
    }

    private func handleCreated(_ active: XAISpeechToTextLiveRun) {
        guard !active.ready else { return }
        active.ready = true
        if active.phase == .connecting { active.phase = .active }
        log("Session ready")
        // Audio held during the handshake leaves first, in capture order.
        pump(active)
    }

    private func handlePartial(
        _ text: String, isFinal: Bool, eventID: String?, _ active: XAISpeechToTextLiveRun
    ) {
        guard isFinal else {
            deliver(text, isFinal: false, active)
            return
        }
        let before = active.accumulated.text
        active.accumulated.append(final: text, eventID: eventID)
        // A retransmitted span is dropped by event identity, not by text:
        // Transcribe 2.0 restates a locked chunk as an utterance final with
        // the same start, while two identical utterances have different starts.
        guard active.accumulated.text != before else { return }
        deliver(text, isFinal: true, active)
    }

    /// `transcript.done` is authoritative for the whole session: a non-empty
    /// one replaces the folded chunk finals rather than appending to them, and
    /// an empty one keeps them (Transcribe 2.0 sends an empty completion after
    /// it has already locked every span). It ends a waiting finish at once,
    /// and that finish returns the whole transcript, so the frame is not also
    /// delivered through `onTranscript`.
    private func handleDone(_ text: String, _ active: XAISpeechToTextLiveRun) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { active.accumulated.replace(with: trimmed) }
        active.doneReceived = true
        if active.phase == .finishing || !active.waiters.isEmpty {
            close(active)
            return
        }
        if !trimmed.isEmpty { deliver(trimmed, isFinal: true, active) }
    }

    /// `finishAndWait()` returns the whole transcript once, so callbacks fall
    /// silent for the frames it consumes.
    private func deliver(_ text: String, isFinal: Bool, _ active: XAISpeechToTextLiveRun) {
        guard active.phase != .finishing else { return }
        active.onTranscript?(text, isFinal)
    }
}
