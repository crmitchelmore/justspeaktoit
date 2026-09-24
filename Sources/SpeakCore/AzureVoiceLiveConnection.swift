import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AzureVoiceLiveClient {
    /// Opens the run's socket. The transport's open is not readiness: only
    /// Azure's acknowledgement of the configuration permits audio.
    func connect(_ active: AzureVoiceLiveRun, request: URLRequest) {
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
            if !active.ready { client.fail(AzureVoiceLiveError.sessionNotReady, active) }
        }
    }

    /// One receive is outstanding at a time and is re-armed only while its run
    /// is current, so a stopped or replaced run never reads again.
    private func receive(_ active: AzureVoiceLiveRun, _ connection: any StreamingWebSocketConnection) {
        guard isCurrent(active) else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error):
                    // Voice Live never ends a session itself, so any closure
                    // before this client finished is a failure.
                    self.fail(error, active)
                case .success(.text(let text)):
                    self.handle(Data(text.utf8), active)
                    self.receive(active, connection)
                case .success(.binary(let data)):
                    self.handle(data, active)
                    self.receive(active, connection)
                }
            }
        }
    }

    /// Voice Live frames are typed JSON objects; anything else is a protocol
    /// failure. Event types this client does not use are ignored.
    func handle(_ data: Data, _ active: AzureVoiceLiveRun) {
        guard isCurrent(active) else { return }
        guard let event = AzureVoiceLiveServerEvent.parse(data) else {
            fail(AzureSpeechError.invalidResponse, active)
            return
        }
        switch event {
        case .sessionCreated, .ignored: break
        case .sessionUpdated: handleSessionUpdated(active)
        case .committed(let item): handleCommitted(item, active)
        case .transcriptionDelta(let item, let delta): handleDelta(delta, item: item, active)
        case .transcriptionCompleted(let item, let text): handleCompleted(text, item: item, active)
        case .transcriptionFailed(let item): handleItemFailed(item, active)
        case .error(let code, let eventID): handleServerError(code, eventID: eventID, active)
        }
    }

    /// Announces the item, and acknowledges the final commit when this client
    /// has handed it over: a `committed` event before that is server VAD's.
    private func handleCommitted(_ item: String?, _ active: AzureVoiceLiveRun) {
        if let item { active.transcript.register(item) }
        if active.phase == .finishing, active.commitSent { active.commitAcknowledged = true }
        settleIfDone(active)
    }

    private func handleDelta(_ delta: String, item: String, _ active: AzureVoiceLiveRun) {
        if active.transcript.append(delta: delta, item: item) { deliverDisplay(active) }
    }

    private func handleCompleted(_ text: String, item: String, _ active: AzureVoiceLiveRun) {
        if active.transcript.complete(text, item: item) { deliverConfirmed(active) }
        settleIfDone(active)
    }

    /// Per item: an unintelligible turn must not discard later ones. A finish
    /// in which every turn failed is reported by `complete`.
    private func handleItemFailed(_ item: String, _ active: AzureVoiceLiveRun) {
        if active.transcript.fail(item: item) {
            log("Item transcription failed")
            deliverDisplay(active)
        }
        settleIfDone(active)
    }

    /// The first acknowledgement after our configuration left is readiness; the
    /// next, once the barrier left, answers the barrier. Any other
    /// `session.updated` answers nothing this run sent and changes nothing.
    private func handleSessionUpdated(_ active: AzureVoiceLiveRun) {
        guard active.sessionUpdateSent else { return }
        if !active.ready {
            active.ready = true
            if active.phase == .connecting { active.phase = .active }
            readiness.markReady()
            log("Session configuration acknowledged")
            // Audio held during the handshake leaves first, in capture order.
            pump(active)
        } else if active.barrierSent, !active.barrierAcknowledged {
            active.barrierAcknowledged = true
            settleIfDone(active)
        }
    }

    /// Every server error ends the run with that error, except the one answer
    /// that concerns only bookkeeping: our own final commit finding the buffer
    /// empty because server VAD had committed everything already. An error
    /// that names the barrier, the configuration or the commit with any other
    /// code is a failure, never a completion.
    private func handleServerError(_ code: String, eventID: String?, _ active: AzureVoiceLiveRun) {
        if code == AzureVoiceLiveProtocol.commitEmptyCode, active.phase == .finishing, active.commitSent,
           eventID == nil || eventID == active.commitEventID {
            log("Final commit found no uncommitted audio")
            active.commitAcknowledged = true
            settleIfDone(active)
            return
        }
        let rejectedConfiguration = eventID == active.sessionEventID || (eventID == nil && !active.ready)
        fail(
            rejectedConfiguration
                ? AzureVoiceLiveError.sessionRejected(code: code) : AzureVoiceLiveError.serverError(code: code),
            active
        )
    }

    /// Ends a finish whose commit and barrier are acknowledged and whose
    /// announced items have all settled.
    func settleIfDone(_ active: AzureVoiceLiveRun) {
        guard isCurrent(active), active.phase == .finishing, active.finishIsSettled else { return }
        complete(active)
    }

    /// After a completion: the confirmed text as a final, then the display as
    /// an interim when other items still have drafts. A finish returns the
    /// whole transcript, so nothing is delivered while finishing.
    private func deliverConfirmed(_ active: AzureVoiceLiveRun) {
        guard active.phase != .finishing else { return }
        let confirmed = active.transcript.confirmed
        if !confirmed.isEmpty, confirmed != active.deliveredConfirmed {
            active.deliveredConfirmed = confirmed
            active.deliveredDisplay = confirmed
            active.onTranscript?(confirmed, true)
            // The callback may have stopped or replaced this run.
            guard isCurrent(active) else { return }
        }
        deliverDisplay(active)
    }

    /// The whole display text restated as an interim, when it changed.
    private func deliverDisplay(_ active: AzureVoiceLiveRun) {
        guard active.phase != .finishing else { return }
        let display = active.transcript.display
        guard !display.isEmpty, display != active.deliveredDisplay else { return }
        active.deliveredDisplay = display
        active.onTranscript?(display, false)
    }
}
