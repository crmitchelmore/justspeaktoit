import Foundation

extension CartesiaLiveClient {
    /// One receive is outstanding per run. A completion delivered while the
    /// loop is still inside `receive` is handed back to the loop, so a
    /// transport that answers synchronously from a buffer cannot grow the stack.
    func receive(_ active: CartesiaLiveRun, _ connection: any StreamingWebSocketConnection) {
        while let generation: UInt64 = withState({ _ in armReceive(active) }) {
            connection.receive { [weak self, weak active] result in
                guard let self, let active else { return }
                let handedBack: Bool = self.withState { _ in
                    guard active.receiveArming, active.receiveGeneration == generation else { return false }
                    active.synchronousReceive = result
                    return true
                }
                guard !handedBack else { return }
                if self.handle(result, generation, active) { self.receive(active, connection) }
            }
            let handedBack: Result<StreamingWebSocketMessage, Error>? = withState { _ in
                active.receiveArming = false
                defer { active.synchronousReceive = nil }
                return active.synchronousReceive
            }
            guard let result = handedBack, handle(result, generation, active) else { return }
        }
    }

    private func armReceive(_ active: CartesiaLiveRun) -> UInt64? {
        guard isCurrent(active) else { return nil }
        active.receiveGeneration += 1
        active.receiveArming = true
        active.synchronousReceive = nil
        return active.receiveGeneration
    }

    /// Applies one receive result and answers whether the loop continues.
    /// Frames are decoded before the lock is taken.
    private func handle(
        _ result: Result<StreamingWebSocketMessage, Error>, _ generation: UInt64, _ active: CartesiaLiveRun
    ) -> Bool {
        let event: CartesiaTurnEvent?
        switch result {
        case .success(.text(let text)): event = CartesiaTurnEvent(data: Data(text.utf8))
        case .success(.binary(let data)): event = CartesiaTurnEvent(data: data)
        case .failure: event = nil
        }
        return withState { effects in
            guard isCurrent(active), active.receiveGeneration == generation else { return false }
            if case .failure(let error) = result {
                closed(by: error, active, &effects)
                return false
            }
            if let event { apply(event, active, &effects) }
            return isCurrent(active)
        }
    }

    private func apply(_ event: CartesiaTurnEvent, _ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        switch event {
        case .connected:
            if recordOpen(active) { effects.add { [weak self] in self?.pump(active) } }
        case .turnStart:
            active.openTurnDraft = nil
            active.withheldDraft = nil
        case .turnResume:
            break
        case .turnUpdate(let text), .turnEagerEnd(let text):
            showDraft(text, active, &effects)
        case .turnEnd(let text):
            confirm(text, active, &effects)
        case .failure(let failure):
            fail(active, CartesiaLiveProtocol.error(for: failure), &effects)
        }
    }

    /// The open turn's cumulative text replaces the previous draft. While a
    /// finish runs it is held back, to be released only if the finish fails.
    private func showDraft(_ text: String, _ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        active.openTurnDraft = text
        guard active.phase != .finishing else {
            active.withheldDraft = text
            return
        }
        guard let callback = active.onTranscript else { return }
        effects.add { callback(text, false) }
    }

    /// A completed turn is confirmed once, by order: `request_id` names the
    /// connection, so identical text in two turns is two utterances. A finish
    /// folds turns that end during it into its return instead of delivering them.
    private func confirm(_ text: String, _ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        active.openTurnDraft = nil
        active.withheldDraft = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        active.accumulated.append(final: text)
        guard active.phase != .finishing else {
            active.withheldFinals.append(text)
            return
        }
        guard let callback = active.onTranscript else { return }
        effects.add { callback(text, true) }
    }

    /// The receive failed: the server closed the stream or the transport
    /// broke. Only a closure after `close` has been sent can end the stream;
    /// if that command's send has not completed yet, its completion settles it.
    private func closed(by error: Error, _ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        guard active.closeSent else {
            fail(active, CartesiaLiveProtocol.connectionError(error), &effects)
            return
        }
        guard active.closeDelivered else {
            active.peerClosure = error
            return
        }
        settle(closure: error, active, &effects)
    }

    /// The documented end of the stream: after `close`, the server flushes its
    /// events and then closes the socket normally. Only that affirmative close
    /// (1000), as the transport reports it, completes a finish. Any other code,
    /// or a transport failure without a close frame, fails it: the words it
    /// flushed are still released to the host and the confirmed text returned.
    /// Words of a turn the server never ended are reported rather than dropped;
    /// a started turn that produced no words loses nothing.
    func settle(closure error: Error, _ active: CartesiaLiveRun, _ effects: inout CartesiaLiveEffects) {
        guard CartesiaLiveProtocol.isNormalClosure(error) else {
            fail(active, CartesiaLiveProtocol.connectionError(error), &effects)
            return
        }
        guard active.openTurnDraft == nil else {
            fail(active, CartesiaStreamingError.incompleteTurn, &effects)
            return
        }
        log("Stream completed")
        retire(active, &effects)
    }
}
