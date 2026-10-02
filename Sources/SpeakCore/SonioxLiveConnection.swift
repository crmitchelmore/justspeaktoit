import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SonioxLiveClient {

    func connect(_ active: SonioxLiveRun, request: URLRequest) {
        let connection = makeConnection(request)
        active.connection = connection
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active), !active.didOpen else { return }
                active.didOpen = true
                // Soniox has no configuration acknowledgement: the completed
                // handshake is readiness. A finishing run keeps its phase.
                if active.phase == .connecting { active.phase = .active }
                self.log("WebSocket handshake completed")
                self.pump(active)
            }
        }
        receive(active, connection)
        // A finish is bounded by its own deadline, which returns what it has.
        after(readyTimeout, active) { client, active in
            if !active.didOpen, active.phase != .finishing {
                client.fail(SonioxStreamingError.connectionFailed, active)
            }
        }
    }

    private func receive(_ active: SonioxLiveRun, _ connection: any StreamingWebSocketConnection) {
        guard isCurrent(active) else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error):
                    // A spurious ENOTCONN re-arms the receive; one that
                    // persists is a stalled transport.
                    guard !WebSocketErrorFilter.isSpuriousDisconnect(error) else {
                        if !self.rearmReceive(active, connection) { self.fail(self.stalledError, active) }
                        return
                    }
                    // Only `finished` proves completion. A dropped socket at
                    // any earlier phase must preserve text as a failed run.
                    self.fail(self.mapReceiveError(error), active)
                case .success(let message):
                    active.ignoredReceiveFailures.reset()
                    let text: String?
                    switch message {
                    case .text(let value): text = value
                    case .binary(let data): text = String(data: data, encoding: .utf8)
                    }
                    if let text, let frame = Self.parse(text) { self.handle(frame, active) }
                    self.receive(active, connection)
                }
            }
        }
    }

    private func rearmReceive(_ active: SonioxLiveRun, _ connection: any StreamingWebSocketConnection) -> Bool {
        guard active.ignoredReceiveFailures.allowsRetry() else { return false }
        after(IgnoredReceiveFailureWindow.retryDelay, active) { client, active in client.receive(active, connection) }
        return true
    }

    // MARK: - Frame handling

    func handle(_ frame: SonioxLiveFrame, _ active: SonioxLiveRun) {
        guard isCurrent(active) else { return }
        if let error = frame.error {
            fail(mapServerError(error), active)
            return
        }

        active.accumulatedFinalText.append(frame.newFinalText)
        if !frame.newFinalText.isEmpty { active.finalVersion += 1 }
        // Interims flow only while streaming. During a finish the whole
        // transcript is either returned by `finishAndWait` or delivered once as
        // a final by `settleFinish`, so nothing is doubled.
        if active.phase == .active {
            let display = active.display(nonFinalTail: frame.nonFinalText)
            if !display.isEmpty { active.onTranscript?(display, false) }
            deliverMarkedFinal(frame, active)
        }

        // `finished` completes the session whenever it arrives. While
        // recording, words it confirmed since the last final are delivered as
        // one first; a finish returns them instead.
        if frame.finished {
            if active.phase == .finishing {
                settleFinish(active)
            } else {
                deliverConfirmedFinal(active)
                close(active)
            }
        }
    }
}

extension SonioxLiveClient {
    /// An endpoint (`<end>`) or finalize (`<fin>`) marker closes an utterance:
    /// the confirmed transcript is delivered once as a final, and a repeated
    /// marker with no new words delivers nothing.
    func deliverMarkedFinal(_ frame: SonioxLiveFrame, _ active: SonioxLiveRun) {
        guard frame.finalized else { return }
        deliverConfirmedFinal(active)
    }

    /// Delivers the confirmed transcript as a final once per new confirmation,
    /// while recording only.
    func deliverConfirmedFinal(_ active: SonioxLiveRun) {
        guard isCurrent(active), active.phase == .active,
              active.finalVersion > active.deliveredFinalVersion, let whole = active.transcript else { return }
        active.deliveredFinalVersion = active.finalVersion
        active.onTranscript?(whole, true)
    }
}
