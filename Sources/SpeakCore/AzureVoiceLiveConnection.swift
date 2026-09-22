import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AzureVoiceLiveClient {
    /// Creates the socket outside the lock and attaches it only while its run
    /// is still current. A run retired meanwhile never resumes its socket, so
    /// no request leaves on behalf of a stopped or replaced session.
    func connect(_ active: AzureVoiceLiveRun, request: URLRequest) {
        let connection = makeConnection(request)
        transact { effects in
            guard isCurrent(active), active.connection == nil else {
                effects.append { connection.cancel() }
                return
            }
            active.connection = connection
            effects.append {
                connection.resume { [weak self, weak active] in
                    guard let self, let active else { return }
                    self.transact { effects in self.opened(active, &effects) }
                }
            }
            effects.append { [weak self, weak active] in
                guard let self, let active else { return }
                self.receive(active, connection)
            }
            // The open socket is not readiness: only Azure's acknowledgement
            // of the configuration permits audio.
            after(Self.readyDeadline, active, &effects) { client, active, effects in
                if !active.ready { client.fail(AzureVoiceLiveError.sessionNotReady, active, &effects) }
            }
        }
    }

    private func opened(_ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        guard isCurrent(active), !active.didOpen else { return }
        active.didOpen = true
        log("WebSocket handshake completed")
        pump(active, &effects)
    }

    /// One receive is outstanding at a time. The next is armed before queued
    /// callbacks are delivered, so a slow host callback does not stall the
    /// socket, while delivery itself stays in order.
    func receive(_ active: AzureVoiceLiveRun, _ connection: any StreamingWebSocketConnection) {
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            var effects = AzureVoiceLiveEffects()
            let rearm = self.lock.withLock { self.consume(result, active, &effects) }
            effects.perform()
            if rearm { self.receive(active, connection) }
            self.deliverPending()
        }
    }

    private func consume(
        _ result: Result<StreamingWebSocketMessage, Error>, _ active: AzureVoiceLiveRun,
        _ effects: inout AzureVoiceLiveEffects
    ) -> Bool {
        guard isCurrent(active) else { return false }
        switch result {
        case .failure(let error):
            fail(error, active, &effects)
            return false
        case .success(.text(let text)):
            handleFrame(Data(text.utf8), active, &effects)
        case .success(.binary(let data)):
            handleFrame(data, active, &effects)
        }
        return isCurrent(active)
    }

    /// Voice Live frames are typed JSON objects; anything else is a protocol
    /// failure. Event types this client does not use are ignored.
    func handleFrame(_ data: Data, _ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        guard let event = AzureVoiceLiveServerEvent.parse(data) else {
            fail(AzureSpeechError.invalidResponse, active, &effects)
            return
        }
        switch event {
        case .sessionCreated, .ignored:
            break
        case .sessionUpdated:
            handleSessionUpdated(active, &effects)
        case .committed(let item):
            active.transcript.register(item)
        case .transcriptionDelta(let item, let delta):
            if active.transcript.append(delta: delta, item: item) { deliverDisplay(active) }
        case .transcriptionCompleted(let item, let text):
            if active.transcript.complete(text, item: item) { deliverConfirmed(active) }
            settleIfDone(active, &effects)
        case .transcriptionFailed(let item):
            // Per item: an unintelligible turn must not discard later ones. A
            // finish in which every turn failed is reported by `complete`.
            if active.transcript.fail(item: item) {
                log("Item transcription failed")
                deliverDisplay(active)
            }
            settleIfDone(active, &effects)
        case .error(let code, let eventID):
            handleServerError(code, eventID: eventID, active, &effects)
        }
    }

    /// The first acknowledgement after our configuration left is readiness; the
    /// next, once the barrier left, settles the barrier. Any other
    /// `session.updated` answers nothing this run sent and changes nothing.
    private func handleSessionUpdated(_ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects) {
        if active.phase == .detached {
            // No transport: the first acknowledgement is the handshake.
            if !active.ready { active.ready = true; readiness.markReady() }
            return
        }
        guard active.sessionUpdateSent else { return }
        if !active.ready {
            active.ready = true
            if active.phase == .connecting { active.phase = .active }
            readiness.markReady()
            log("Session configuration acknowledged")
            // Audio held during the handshake leaves first, in capture order.
            pump(active, &effects)
        } else if active.barrierSent, !active.barrierSettled {
            active.barrierSettled = true
            settleIfDone(active, &effects)
        }
    }

    /// Errors end the session, except two that concern only finalisation
    /// bookkeeping and still carry its ordering guarantee.
    private func handleServerError(
        _ code: String, eventID: String?, _ active: AzureVoiceLiveRun, _ effects: inout AzureVoiceLiveEffects
    ) {
        if code == AzureVoiceLiveProtocol.commitEmptyCode, active.phase == .finishing, active.finalCommitSent,
           eventID == nil || eventID == active.commitEventID {
            // Server VAD had already committed every appended frame, so our
            // commit found nothing. Items VAD created were announced before
            // this error; the barrier, not this error, decides that all of
            // them are known, so it never ends the finish on its own.
            log("Final commit found no uncommitted audio")
            return
        }
        if eventID == active.barrierEventID, active.barrierSent, !active.barrierSettled {
            // Only the no-op modality restatement was refused. Azure answers
            // events in order, so this still proves everything before it ran.
            log("Finalisation barrier refused; ordering still established")
            active.barrierSettled = true
            settleIfDone(active, &effects)
            return
        }
        fail(AzureVoiceLiveError.serverError(code: code), active, &effects)
    }

    /// After a completion: the confirmed text as a final, then the display
    /// text as an interim when other items still have drafts.
    private func deliverConfirmed(_ active: AzureVoiceLiveRun) {
        guard active.phase != .finishing, let callback = active.onTranscript else { return }
        let confirmed = active.transcript.confirmed
        if !confirmed.isEmpty, confirmed != active.deliveredConfirmed {
            active.deliveredConfirmed = confirmed
            active.deliveredDisplay = confirmed
            deliveries.append(.transcript(callback, text: confirmed, isFinal: true))
        }
        deliverDisplay(active)
    }

    /// The whole display text restated as an interim, when it changed. A
    /// finish returns the whole transcript, so nothing is delivered while finishing.
    private func deliverDisplay(_ active: AzureVoiceLiveRun) {
        guard active.phase != .finishing, let callback = active.onTranscript else { return }
        let display = active.transcript.display
        guard !display.isEmpty, display != active.deliveredDisplay else { return }
        active.deliveredDisplay = display
        deliveries.append(.transcript(callback, text: display, isFinal: false))
    }
}
