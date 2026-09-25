import Foundation

extension RevAILiveClient {
    /// One receive is outstanding per run. A completion delivered while the
    /// loop is still inside `receive` is handed back to the loop, so a
    /// transport that answers synchronously from a buffer cannot grow the stack.
    func receive(_ active: RevAILiveRun, _ connection: any StreamingWebSocketConnection) {
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

    private func armReceive(_ active: RevAILiveRun) -> UInt64? {
        guard isCurrent(active) else { return nil }
        active.receiveGeneration += 1
        active.receiveArming = true
        active.synchronousReceive = nil
        return active.receiveGeneration
    }

    /// Applies one receive result and answers whether the loop continues.
    /// Frames are decoded before the lock is taken.
    private func handle(
        _ result: Result<StreamingWebSocketMessage, Error>, _ generation: UInt64, _ active: RevAILiveRun
    ) -> Bool {
        let event: RevAIStreamingEvent?
        switch result {
        case .success(let message): event = RevAIStreamingEvent(message: message)
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

    private func apply(_ event: RevAIStreamingEvent, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        switch event {
        case .connected:
            guard !active.ready else { return }
            active.ready = true
            if active.phase == .connecting { active.phase = .streaming }
            log("Session connected")
            if let outbound = claim(active, &effects) {
                effects.add { [weak self] in self?.drive(outbound) }
            }
        case .partial(let text):
            showPartial(text, active, &effects)
        case .final(let text):
            confirm(text, active, &effects)
        }
    }

    /// A partial restates the open segment's words and replaces the previous
    /// one. While a finish runs it is held back, to be released only if the
    /// finish fails; an empty one withdraws the words without a delivery.
    private func showPartial(_ text: String, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard !text.isEmpty else {
            active.openPartial = nil
            active.withheldPartial = nil
            return
        }
        active.openPartial = text
        guard active.phase != .finishing else {
            active.withheldPartial = text
            return
        }
        deliver(text, isFinal: false, active, &effects)
    }

    /// A final ends its segment, with or without words, and is confirmed once,
    /// by order: each covers a new window of audio, so identical text in two
    /// finals is two utterances (issue #700). A finish folds finals that arrive
    /// during it into its return instead of delivering them.
    private func confirm(_ text: String, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        active.openPartial = nil
        active.withheldPartial = nil
        guard !text.isEmpty else { return }
        active.accumulated.append(final: text)
        guard active.phase != .finishing else {
            active.withheldFinals.append(text)
            return
        }
        deliver(text, isFinal: true, active, &effects)
    }

    /// Hands a transcript to the host outside the lock and counts it until the
    /// callback returns, so a failure decided meanwhile is reported after it.
    private func deliver(
        _ text: String, isFinal: Bool, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects
    ) {
        guard let callback = active.onTranscript else { return }
        active.transcriptsInFlight += 1
        effects.add {
            callback(text, isFinal)
            self.withState { effects in self.transcriptReturned(active, &effects) }
        }
    }

    /// The receive failed: the server closed the stream or the transport
    /// broke. Only a closure after `EOS` was handed to the transport can end
    /// the stream; one while it is merely claimed, or after a send failed, did
    /// not answer it. If `EOS`'s send has not completed yet, its completion
    /// settles the closure.
    private func closed(by error: Error, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard active.endOfStreamSent, active.sendFailure == nil else {
            fail(active, interruption(by: error), &effects)
            return
        }
        guard active.endOfStreamDelivered else {
            active.peerClosure = error
            return
        }
        settle(closure: error, active, &effects)
    }

    /// The documented end of the stream: after `EOS`, Rev AI sends the final
    /// hypothesis and closes the socket. Only that affirmative close (1000),
    /// as the transport reports it, completes a finish, and only once the last
    /// partial has had its final. Any other status, or a transport failure
    /// without a close frame, fails it: the words it flushed are still released
    /// to the host and the confirmed text returned.
    func settle(closure error: Error, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        let closeCode = (error as? StreamingWebSocketCloseReporting)?.webSocketCloseCode
        guard closeCode == RevAIStreaming.normalClosureCode else {
            fail(active, interruption(by: error), &effects)
            return
        }
        guard active.openPartial == nil else {
            fail(active, RevAILiveError.incompleteSegment, &effects)
            return
        }
        log("Stream completed")
        retire(active, &effects)
    }

    /// The error a stream that ended without completing reports: a normal
    /// closure that did not answer a delivered `EOS` is an early end, a
    /// documented status names its cause, any other status is an unexpected
    /// closure, and a failure without a close frame is the transport's own.
    func interruption(by error: Error) -> Error {
        guard let code = (error as? StreamingWebSocketCloseReporting)?.webSocketCloseCode else { return error }
        guard code != RevAIStreaming.normalClosureCode else { return RevAILiveError.unexpectedCompletion }
        return RevAIStreamingError.error(closeCode: code)
    }
}
