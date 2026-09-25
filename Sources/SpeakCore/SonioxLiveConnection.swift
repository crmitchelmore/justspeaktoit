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
        after(Self.readyDeadline, active) { client, active in
            if !active.didOpen { client.fail(SonioxStreamingError.connectionFailed, active) }
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
                    // Only `finished` proves completion. A dropped socket at
                    // any earlier phase must preserve text as a failed run.
                    self.fail(self.mapReceiveError(error), active)
                case .success(let message):
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

    // MARK: - Frame handling

    func handle(_ frame: SonioxLiveFrame, _ active: SonioxLiveRun) {
        guard isCurrent(active) else { return }
        if let error = frame.error {
            fail(mapServerError(error), active)
            return
        }

        active.accumulatedFinalText.append(frame.newFinalText)
        // Interims flow only while streaming. During a finish the whole
        // transcript is either returned by `finishAndWait` or delivered once as
        // a final by `settleFinish`, so nothing is doubled.
        if active.phase == .active {
            let display = active.display(nonFinalTail: frame.nonFinalText)
            if !display.isEmpty { active.onTranscript?(display, false) }
        }

        if frame.finished {
            if active.phase == .finishing, active.endOfStreamSent {
                settleFinish(active)
            } else if active.connection == nil {
                // Preserve the socket-free parser seam for existing contracts.
                close(active)
            } else {
                fail(SonioxStreamingError.unexpectedCompletion, active)
            }
        }
    }
}
