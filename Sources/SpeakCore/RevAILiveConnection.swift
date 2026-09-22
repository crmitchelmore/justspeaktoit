import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Request

extension RevAILiveClient {
    /// Rev AI authenticates the streaming socket with an `access_token` query
    /// parameter; `Authorization: Bearer` is documented only for its HTTP
    /// endpoints, so the header is deliberately not sent. The URL carries the
    /// token and is never logged.
    static func webSocketURL(
        accessToken: String,
        sampleRate: Int,
        language: String?,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = RevAIStreaming.webSocketHost
        components.path = RevAIStreaming.webSocketPath
        var items = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(
                name: "content_type", value: RevAIStreaming.rawPCMContentType(sampleRate: sampleRate)
            ),
            URLQueryItem(name: "transcriber", value: RevAIStreaming.transcriber)
        ]
        if let code = RevAIStreaming.languageCode(
            for: language, systemLocaleIdentifier: systemLocaleIdentifier
        ) {
            items.append(URLQueryItem(name: "language", value: code))
        }
        components.queryItems = items
        return components.url
    }

    static func webSocketRequest(accessToken: String, sampleRate: Int, language: String?) -> URLRequest? {
        webSocketURL(accessToken: accessToken, sampleRate: sampleRate, language: language).map { URLRequest(url: $0) }
    }
}

// MARK: - Connection and receive

extension RevAILiveClient {
    /// Creates this run's one socket. The factory runs outside the lock, so
    /// the run can be retired while it does; that socket is then cancelled and
    /// never resumed. Nothing reconnects.
    func connect(_ active: RevAILiveRun, request: URLRequest) {
        let connection = makeConnection(request)
        let attached: Bool = lock.withLock {
            guard isCurrent(active) else { return false }
            active.connection = connection
            return true
        }
        guard attached else {
            connection.cancel()
            return
        }
        after(Self.readyDeadline, active) { client, active, effects in
            if !active.isReady { client.fail(RevAILiveError.sessionNotReady, active, &effects) }
        }
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.opened(active)
        }
        // A retirement racing the resume has cancelled this socket, possibly
        // before the resume. Cancelling again keeps it closed either way.
        if !lock.withLock({ isCurrent(active) }) { connection.cancel() }
        receive(active, connection)
    }

    private func opened(_ active: RevAILiveRun) {
        withState { effects in
            guard isCurrent(active), !active.didOpen else { return }
            active.didOpen = true
            log("WebSocket handshake completed")
            if active.isReady { becameReady(active, &effects) }
        }
    }

    private func becameReady(_ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        if active.phase == .connecting { active.phase = .streaming }
        log("Session connected")
        requestPump(active, &effects)
    }

    /// Keeps exactly one receive outstanding. A transport that answers from a
    /// queue of complete messages completes synchronously; the loop then asks
    /// again instead of recursing once per message.
    func receive(_ active: RevAILiveRun, _ connection: any StreamingWebSocketConnection) {
        let owner: Bool = lock.withLock {
            guard isCurrent(active) else { return false }
            guard !active.receiving else {
                active.receiveRequested = true
                return false
            }
            active.receiving = true
            return true
        }
        guard owner else { return }
        var again = true
        while again {
            lock.withLock { active.receiveRequested = false }
            connection.receive { [weak self, weak active] result in
                guard let self, let active else { return }
                self.received(result, active)
            }
            again = lock.withLock {
                let requested = active.receiveRequested && isCurrent(active)
                if !requested { active.receiving = false }
                return requested
            }
        }
    }

    private func received(_ result: Result<StreamingWebSocketMessage, Error>, _ active: RevAILiveRun) {
        let next: (any StreamingWebSocketConnection)? = withState { effects in
            guard isCurrent(active) else { return nil }
            switch result {
            case .failure(let error):
                receiveFailed(error, active, &effects)
                return nil
            case .success(let message):
                handle(message, active, &effects)
                return isCurrent(active) ? active.connection : nil
            }
        }
        // The next message is requested only after this one's callbacks ran.
        if let next { receive(active, next) }
    }

    /// Rev AI has exactly three frame types; anything else decodes to `nil`
    /// and is ignored, because an unrecognised frame must never end a live
    /// recording. `connected` is readiness; transcripts carry no readiness.
    func handle(_ message: StreamingWebSocketMessage, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard isCurrent(active), let event = RevAIStreamingEvent(message: message) else { return }
        switch event {
        case .connected:
            guard !active.connectedFrame else { return }
            active.connectedFrame = true
            if active.isReady { becameReady(active, &effects) }
        case .partial(let text):
            deliver(text, isFinal: false, active, &effects)
        case .final(let text):
            active.confirmed.append(final: text)
            deliver(text, isFinal: true, active, &effects)
        }
    }

    /// Callbacks flow while streaming. During a finish the whole confirmed
    /// transcript is returned by `finishAndWait`, so nothing is delivered
    /// twice, and the host keeps the draft it last showed.
    private func deliver(_ text: String, isFinal: Bool, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        guard active.phase == .connecting || active.phase == .streaming,
              let callback = active.onTranscript else { return }
        effects.append { callback(text, isFinal) }
    }

    /// Only a close frame reporting 1000 once `EOS` has left, behind every
    /// admitted frame, completes the stream. Every other ending is a failure
    /// that keeps the confirmed text: a documented Rev AI close code names its
    /// cause, a 1000 before `EOS` ended the stream early, and a failure that
    /// reports no close frame at all ended it without confirmation.
    func receiveFailed(_ error: Error, _ active: RevAILiveRun, _ effects: inout RevAILiveEffects) {
        let closeCode = (error as? StreamingWebSocketCloseReporting)?.webSocketCloseCode
        if closeCode == RevAIStreaming.normalClosureCode, active.acceptsCompletion {
            log("Stream completed")
            close(active, &effects)
            return
        }
        fail(failure(for: error, closeCode: closeCode, active), active, &effects)
    }

    /// The error a failed receive or send publishes.
    func failure(for error: Error, closeCode: Int?, _ active: RevAILiveRun) -> Error {
        if let closeCode {
            if let documented = RevAIStreamingError.forCloseCode(closeCode) { return documented }
            if closeCode == RevAIStreaming.normalClosureCode { return RevAILiveError.unexpectedCompletion }
            return RevAIStreamingError.closed(closeCode: closeCode)
        }
        return active.endOfStreamHandedOff ? RevAILiveError.missingCompletion : error
    }
}
