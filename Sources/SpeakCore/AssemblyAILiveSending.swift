import Foundation

extension AssemblyAILiveClient {
    private enum Payload: Sendable { case audio(Int), forceEndpoint, terminate }

    func pump(_ active: AssemblyAILiveRun) {
        guard isCurrent(active), !active.sending, let attempt = active.attempt,
              attempt.didOpen, attempt.didBegin else { return }
        guard let (message, payload) = nextPayload(active) else { return }
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        attempt.connection.send(message) { [weak self, weak active, weak attempt] error in
            guard let self, let active, let attempt else { return }
            self.synchronized {
                self.completeSend(error, payload: payload, sendID: sendID, active: active, attempt: attempt)
            }
        }
        after(5, active) { client, active in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active) }
        }
    }

    private func completeSend(
        _ error: Error?, payload: Payload, sendID: UInt64,
        active: AssemblyAILiveRun, attempt: AssemblyAILiveRun.Attempt
    ) {
        guard isCurrent(active, attempt), active.sending, active.sendID == sendID else { return }
        active.sending = false
        if case .audio(let bytes) = payload { active.budget.release(bytes) }
        if let error { transportFailed(error, active, attempt); return }
        switch payload {
        case .audio: pump(active)
        case .forceEndpoint:
            active.ending = active.finalAfterForce ? .terminateReady : .awaitingFinal
            if active.finalAfterForce { pump(active) } else { waitForFormattedTurn(active) }
        case .terminate:
            active.ending = .sent
            after(3, active) { client, active in client.close(active) }
        }
    }

    private func nextPayload(_ active: AssemblyAILiveRun) -> (StreamingWebSocketMessage, Payload)? {
        let message: StreamingWebSocketMessage
        let payload: Payload
        if !active.outgoing.isEmpty {
            let data = active.outgoing.removeFirst()
            message = .binary(data)
            payload = .audio(data.count)
        } else if active.phase == .finishing, active.ending == .none {
            active.ending = .forceInFlight
            message = .text(#"{"type":"ForceEndpoint"}"#)
            payload = .forceEndpoint
        } else if active.phase == .finishing, active.ending == .terminateReady {
            active.ending = .terminateInFlight
            message = .text(#"{"type":"Terminate"}"#)
            payload = .terminate
        } else { return nil }
        return (message, payload)
    }

    private func waitForFormattedTurn(_ active: AssemblyAILiveRun) {
        let budget = ModelCatalog.liveCapabilities(for: AssemblyAIModels.universal35ProStreamingID)
            .postStopFinalizeBudget
        after(budget, active) { client, active in
            guard active.ending == .awaitingFinal else { return }
            active.ending = .terminateReady
            client.pump(active)
        }
    }
}
