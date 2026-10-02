import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AssemblyAILiveClient {
    func connect(_ active: AssemblyAILiveRun, host: AssemblyAIStreamingEndpoint) {
        guard isCurrent(active), active.phase != .finishing else { return }
        guard let request = makeRequest(endpoint: host) else { fail(StreamingClientError.invalidURL, active); return }
        let attempt = AssemblyAILiveRun.Attempt(connection: makeConnection(request), host: host)
        active.attempt = attempt
        attempt.connection.resume { [weak self, weak active, weak attempt] in
            guard let self, let active, let attempt else { return }
            self.synchronized {
                guard self.isCurrent(active, attempt) else { return }
                attempt.didOpen = true
                self.pump(active)
            }
        }
        receive(active, attempt)
        after(8, active) { [weak attempt] client, active in
            guard let attempt, client.isCurrent(active, attempt), !attempt.didBegin else { return }
            client.transportFailed(AssemblyAIStreamingError.beginTimeout, active, attempt)
        }
    }

    func transportFailed(_ error: Error, _ active: AssemblyAILiveRun, _ attempt: AssemblyAILiveRun.Attempt) {
        guard isCurrent(active, attempt) else { return }
        if !attempt.didBegin, !active.attemptedFallback, attempt.host == .europe, active.phase != .finishing {
            active.attemptedFallback = true
            active.attempt = nil
            attempt.connection.cancel()
            connect(active, host: .global)
            return
        }
        if active.phase == .finishing, active.ending == .sent { close(active) } else { fail(error, active) }
    }

    func receive(_ active: AssemblyAILiveRun, _ attempt: AssemblyAILiveRun.Attempt) {
        guard isCurrent(active, attempt) else { return }
        attempt.connection.receive { [weak self, weak active, weak attempt] result in
            guard let self, let active, let attempt else { return }
            self.synchronized {
                guard self.isCurrent(active, attempt) else { return }
                switch result {
                case .failure(let error):
                    // A spurious ENOTCONN, typically around the handshake, re-arms
                    // the receive. It never ends the session or spends the one
                    // EU-to-global fallback; only one that persists does.
                    if WebSocketErrorFilter.isSpuriousDisconnect(error), self.rearmReceive(active, attempt) { return }
                    self.transportFailed(error, active, attempt)
                case .success(let message):
                    attempt.ignoredReceiveFailures.reset()
                    let data: Data
                    switch message {
                    case .text(let text): data = Data(text.utf8)
                    case .binary(let bytes): data = bytes
                    }
                    self.parse(data, active, attempt)
                    self.receive(active, attempt)
                }
            }
        }
    }

    /// Re-arms the receive shortly after an ignorable failure, or answers
    /// false once such failures have persisted past their window.
    private func rearmReceive(_ active: AssemblyAILiveRun, _ attempt: AssemblyAILiveRun.Attempt) -> Bool {
        guard attempt.ignoredReceiveFailures.allowsRetry() else { return false }
        after(IgnoredReceiveFailureWindow.retryDelay, active) { [weak attempt] client, active in
            guard let attempt else { return }
            client.receive(active, attempt)
        }
        return true
    }

    private func parse(_ data: Data, _ active: AssemblyAILiveRun, _ attempt: AssemblyAILiveRun.Attempt) {
        guard let envelope = try? JSONDecoder().decode(AssemblyAIEnvelope.self, from: data) else { return }
        let type = envelope.type ?? (envelope.turn_order != nil ? "Turn" : "")
        switch type {
        case "Begin":
            guard !attempt.didBegin else { return }
            attempt.didBegin = true
            if active.phase == .connecting { active.phase = .active }
            pump(active)
        case "Turn": receiveTurn(data, active, attempt)
        case "Termination":
            if active.phase == .finishing,
               active.ending == .terminateInFlight || active.ending == .sent {
                close(active)
            } else { fail(AssemblyAIStreamingError.serverFailure, active) }
        case "Error": transportFailed(AssemblyAIStreamingError.serverFailure, active, attempt)
        default: break
        }
    }

    private func receiveTurn(_ data: Data, _ active: AssemblyAILiveRun, _ attempt: AssemblyAILiveRun.Attempt) {
        guard attempt.didBegin,
              let turn = try? JSONDecoder().decode(AssemblyAIStreamingTurn.self, from: data),
              let update = active.assembler.consume(turn) else { return }
        // A callback may itself call stop(). Its triggering Turn predates
        // ForceEndpoint and must not count as the response to that new request.
        let endingWhenReceived = active.ending
        // The provider's closed utterance is an explicit boundary, reported
        // during a finish too, ahead of the turn's transcript update.
        if let utterance = turn.utterance?.trimmingCharacters(in: .whitespacesAndNewlines), !utterance.isEmpty {
            onUtteranceBoundary?(utterance)
            guard isCurrent(active, attempt) else { return }
        }
        if active.phase != .finishing || active.deliverWhileFinishing {
            active.onTranscript?(update.displayText, false)
        }
        // Callback clients may synchronously cancel/start another session.
        guard isCurrent(active, attempt) else { return }
        if update.finalizedTurn, active.phase == .finishing,
           endingWhenReceived == .forceInFlight || endingWhenReceived == .awaitingFinal {
            if active.ending == .forceInFlight { active.finalAfterForce = true }
            if active.ending == .awaitingFinal { holdTerminateForGrace(active) }
        }
    }
}
