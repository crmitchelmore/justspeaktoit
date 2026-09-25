import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension OpenAIRealtimeLiveClient {
    func connect(_ active: OpenAIRealtimeLiveRun, request: URLRequest) {
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
        after(Self.readyDeadline, active) { client, active in
            if !active.ready { client.fail(OpenAIRealtimeStreamingError.sessionNotReady, active) }
        }
    }

    private func receive(_ active: OpenAIRealtimeLiveRun, _ connection: any StreamingWebSocketConnection) {
        guard isCurrent(active) else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error):
                    self.fail(error, active)
                case .success(let message):
                    let text: String?
                    switch message {
                    case .text(let value): text = value
                    case .binary(let data): text = String(data: data, encoding: .utf8)
                    }
                    if let text, let event = OpenAIRealtimeServerEvent.parse(text) { self.handle(event, active) }
                    self.receive(active, connection)
                }
            }
        }
    }

    private func handle(_ event: OpenAIRealtimeServerEvent, _ active: OpenAIRealtimeLiveRun) {
        switch event {
        case .sessionCreated:
            active.onEvent?(.sessionCreated)
        case .sessionUpdated(let sessionType):
            handleSessionUpdated(sessionType, active)
        case .inputAudioBufferCommitted(let itemID, _):
            let key = OpenAIRealtimeTranscriptAssembler.key(forItemID: itemID)
            active.assembler.noteCommitted(itemKey: key)
            // With manual turn detection disabled, ordered commit commands
            // receive ordered acknowledgements; transcription completions can
            // arrive in any order. A duplicate ACK cannot consume the next one.
            if !itemID.isEmpty, !active.itemKeysByCommit.values.contains(key), !active.commitsAwaitingAck.isEmpty {
                let sequence = active.commitsAwaitingAck.removeFirst()
                active.itemKeysByCommit[sequence] = key
            }
            finishIfSettled(active)
        case .transcriptionDelta(let itemID, let delta):
            let text = active.assembler.consume(delta: delta, itemID: itemID)
            active.onEvent?(.delta(delta, itemId: itemID))
            deliverTranscript(text, isFinal: false, active)
        case .transcriptionCompleted(let itemID, let transcript):
            handleCompleted(itemID, transcript, active)
        case .transcriptionFailed(let itemID, _, let message):
            let error = OpenAIRealtimeStreamingError.transcriptionFailed(itemID: itemID, message: message)
            let key = OpenAIRealtimeTranscriptAssembler.key(forItemID: itemID)
            active.failedItemKeys.insert(key)
            if active.phase == .finishing, active.finalCommitItemKey == key {
                fail(error, active)
            } else {
                active.onError?(error)
                finishIfSettled(active)
            }
        case .error(let code, let message, let eventID):
            handleServerError(code, message, eventID: eventID, active)
        case .ignored:
            break
        }
    }

    /// `session.created` is not readiness. Only an acknowledgement that follows
    /// our own `session.update`, for a transcription session, releases audio.
    private func handleSessionUpdated(_ sessionType: String?, _ active: OpenAIRealtimeLiveRun) {
        if let sessionType, sessionType != OpenAIRealtimeProtocol.transcriptionSessionType {
            fail(OpenAIRealtimeStreamingError.unexpectedSessionType(sessionType), active)
            return
        }
        guard active.sessionUpdateSent, !active.ready else { return }
        active.ready = true
        if active.phase == .connecting { active.phase = .active }
        log("Session configuration acknowledged")
        // The queued prefix enters the transport before anyone waiting on
        // readiness resumes, so a following pending-send wait covers it.
        pump(active)
        active.onEvent?(.sessionReady)
        guard isCurrent(active) else { return }
        active.resolveAllReadyWaiters(value: true)
        if active.isDrained { active.resolveAllDrainWaiters() }
    }

    private func handleCompleted(_ itemID: String, _ transcript: String, _ active: OpenAIRealtimeLiveRun) {
        let text = active.assembler.consume(completed: transcript, itemID: itemID)
        active.onEvent?(.completed(transcript, itemId: itemID))
        deliverTranscript(text, isFinal: true, active)
        // A callback may cancel or restart; only the current finishing run closes here.
        finishIfSettled(active)
    }

    private func finishIfSettled(_ active: OpenAIRealtimeLiveRun) {
        guard isCurrent(active), active.phase == .finishing, active.finishIsSettled else { return }
        close(active)
    }

    /// "Most errors are recoverable and the session will stay open", so errors
    /// are reported and the run continues; a configuration that is never
    /// acknowledged still ends at the readiness deadline. Once a commit is in
    /// transport during finalisation no completion can follow, so that ends the
    /// finish with the error and the best available text.
    private func handleServerError(
        _ code: String, _ message: String, eventID: String?, _ active: OpenAIRealtimeLiveRun
    ) {
        let error = OpenAIRealtimeStreamingError.serverError(code: code, message: message)
        if let sequence = active.commitSequence(forEventID: eventID), sequence <= active.commitSequence {
            active.failedCommits.insert(sequence)
            active.commitsAwaitingAck.removeAll { $0 == sequence }
            if active.phase == .finishing, active.finalCommitSequence == sequence {
                fail(error, active)
            } else {
                active.onError?(error)
                finishIfSettled(active)
            }
        } else if eventID == active.sessionUpdateEventID {
            fail(error, active)
        } else if eventID == nil, active.phase == .finishing,
                  active.finalCommitSent || !active.commitsAwaitingAck.isEmpty {
            fail(error, active)
        } else {
            active.onError?(error)
        }
    }

    private func deliverTranscript(_ text: String, isFinal: Bool, _ active: OpenAIRealtimeLiveRun) {
        guard active.phase != .finishing || active.deliverWhileFinishing else { return }
        active.onTranscript?(text, isFinal)
    }
}
