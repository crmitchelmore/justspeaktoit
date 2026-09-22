import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Connection and receive

extension MistralVoxtralLiveClient {
    func connect(_ active: MistralVoxtralLiveRun, request: URLRequest) {
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
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.withState { effects in
                guard self.isCurrent(active), !active.didOpen else { return }
                active.didOpen = true
                self.log("WebSocket handshake completed")
                self.requestPump(active, &effects)
            }
        }
        receive(active, connection)
        after(Self.readyDeadline, active) { client, active, effects in
            if !active.configured { client.fail(MistralRealtimeStreamingError.sessionNotReady, active, &effects) }
        }
    }

    /// Keeps exactly one receive outstanding. A transport that answers from a
    /// queue of complete messages completes synchronously; the loop then asks
    /// again instead of recursing once per message.
    func receive(_ active: MistralVoxtralLiveRun, _ connection: any StreamingWebSocketConnection) {
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
                self.received(result, active, connection)
            }
            again = lock.withLock {
                let requested = active.receiveRequested && isCurrent(active)
                if !requested { active.receiving = false }
                return requested
            }
        }
    }

    private func received(
        _ result: Result<StreamingWebSocketMessage, Error>, _ active: MistralVoxtralLiveRun,
        _ connection: any StreamingWebSocketConnection
    ) {
        let proceed: Bool = withState { effects in
            guard isCurrent(active) else { return false }
            switch result {
            case .failure(let error):
                fail(transportError(error, active), active, &effects)
                return false
            case .success(let message):
                handle(message, active, &effects)
                return isCurrent(active)
            }
        }
        // The next message is requested only after this one's callbacks ran.
        if proceed { receive(active, connection) }
    }

    /// Once the flush has left, only `transcription.done` completes the
    /// session, so a failed receive or send then is a missing completion,
    /// whichever of the two the transport reports first. Earlier, the
    /// transport's own error is the failure.
    func transportError(_ error: Error, _ active: MistralVoxtralLiveRun) -> Error {
        if active.phase == .finishing, active.flushHandedOff { return MistralRealtimeStreamingError.missingCompletion }
        return mapConnectionError(error)
    }

    /// Only an explicit `error` event ends the session; everything the app
    /// does not act on (`session.updated`, `transcription.language`,
    /// `transcription.segment`, anything added upstream, anything that is not
    /// JSON) decodes to `nil` and is ignored.
    func handle(_ message: StreamingWebSocketMessage, _ active: MistralVoxtralLiveRun,
                _ effects: inout MistralVoxtralLiveEffects) {
        guard isCurrent(active), let event = MistralRealtimeEvent(message: message) else { return }
        switch event {
        case .sessionCreated:
            guard !active.sessionCreated else { return }
            active.sessionCreated = true
            log("Session created")
            requestPump(active, &effects)
        case .delta(let fragment):
            handleDelta(fragment, active, &effects)
        case .done(let text):
            handleDone(text, active, &effects)
        case .failure(let message, let code):
            // An error before `session.created` is a handshake rejection,
            // which is how a bad key or a blocked account arrives.
            let error = active.sessionCreated
                ? MistralRealtimeError.server(message: message, code: code)
                : MistralRealtimeError.handshakeRejected(message: message)
            fail(error, active, &effects)
        }
    }

    /// Deltas are append-only fragments; every other provider here reports
    /// cumulative interim text, so the folding happens on this side.
    private func handleDelta(_ fragment: String, _ active: MistralVoxtralLiveRun,
                             _ effects: inout MistralVoxtralLiveEffects) {
        active.streamedText += fragment
        let running = active.streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running.isEmpty, let callback = active.onTranscript else { return }
        effects.append { callback(running, false) }
    }

    /// A non-empty `transcription.done` is authoritative for the whole session
    /// and replaces the folded deltas; an empty one keeps them. After the flush
    /// has left it completes the finish at once, which returns the text, so it
    /// is not also delivered as a final. Earlier, audio the recording still
    /// held can no longer be transcribed, so the run fails with the text kept.
    private func handleDone(_ text: String, _ active: MistralVoxtralLiveRun,
                            _ effects: inout MistralVoxtralLiveEffects) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { active.completedText = trimmed }
        guard active.connection != nil else {
            // The socket-free parser seam keeps its established contract.
            if !active.waiters.isEmpty {
                close(active, &effects)
            } else if let final = active.transcript, let callback = active.onTranscript {
                effects.append { callback(final, true) }
            }
            return
        }
        if active.phase == .finishing, active.flushHandedOff {
            close(active, &effects)
        } else {
            fail(MistralRealtimeStreamingError.unexpectedCompletion, active, &effects)
        }
    }

    /// An HTTP 401/403 upgrade rejection is an invalid key. Nothing here logs
    /// the key, a frame or transcript text.
    func mapConnectionError(_ error: Error) -> Error {
        let description = (error as NSError).localizedDescription.lowercased()
        if description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Mistral")
        }
        return error
    }
}

// MARK: - Sending

extension MistralVoxtralLiveClient {
    private struct PendingSend {
        let connection: any StreamingWebSocketConnection
        let item: MistralVoxtralLiveRun.Outbound
        let sendID: UInt64
    }

    func requestPump(_ active: MistralVoxtralLiveRun, _ effects: inout MistralVoxtralLiveEffects) {
        effects.append { [weak self] in self?.pump(active) }
    }

    /// Exactly one send is in flight, in queue order. The loop owns the queue
    /// until nothing more can move; a completion that arrives while it runs,
    /// synchronously or on another thread, only clears `sending`, and the loop
    /// sends the next frame. Encoding happens here, outside the lock.
    func pump(_ active: MistralVoxtralLiveRun) {
        let owner: Bool = lock.withLock {
            guard isCurrent(active), !active.pumping else { return false }
            active.pumping = true
            return true
        }
        guard owner else { return }
        while let next = lock.withLock({ () -> PendingSend? in nextSend(active) }) {
            transmit(next, active)
        }
    }

    /// Takes the next sendable frame, or releases the loop in the same critical
    /// section that found nothing, so no newly queued work is stranded.
    private func nextSend(_ active: MistralVoxtralLiveRun) -> PendingSend? {
        guard isCurrent(active), !active.sending, let connection = active.connection,
              let head = active.outgoing.first, active.canSend(head) else {
            active.pumping = false
            return nil
        }
        let item = active.takeNext()
        return PendingSend(connection: connection, item: item, sendID: active.sendID)
    }

    private func transmit(_ next: PendingSend, _ active: MistralVoxtralLiveRun) {
        let text: String
        switch next.item {
        case .sessionUpdate: text = Self.sessionUpdateFrame(sampleRate: sampleRate)
        case .audio(let pcm): text = Self.appendFrame(for: pcm)
        case .flush: text = Self.flushFrame
        case .end: text = Self.endFrame
        }
        let sent = MistralVoxtralLiveRun.Sent(next.item)
        let sendID = next.sendID
        after(Self.sendDeadline, active) { client, active, effects in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active, &effects) }
        }
        next.connection.send(.text(text)) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.completeSend(error, sent, sendID: sendID, active)
        }
    }

    private func completeSend(_ error: Error?, _ sent: MistralVoxtralLiveRun.Sent, sendID: UInt64,
                              _ active: MistralVoxtralLiveRun) {
        withState { effects in
            guard isCurrent(active), active.sending, active.sendID == sendID else { return }
            active.sending = false
            if case .audio(let bytes) = sent {
                active.bufferedFrames -= 1
                active.bufferedBytes -= bytes
            }
            if let error {
                // A failed drain or control frame is visible, never a success
                // with truncated text.
                fail(transportError(error, active), active, &effects)
                return
            }
            if case .sessionUpdate = sent {
                active.configured = true
                if active.phase == .connecting { active.phase = .streaming }
                log("Session configured")
            }
            requestPump(active, &effects)
        }
    }
}

// MARK: - Protocol frames

extension MistralVoxtralLiveClient {
    /// `model` is the socket's only query parameter: the audio format and the
    /// streaming delay travel in `session.update` instead.
    static func webSocketURL(model: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = MistralVoxtralRealtime.webSocketHost
        components.path = MistralVoxtralRealtime.webSocketPath
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url
    }

    /// A native app can set the handshake header, so the long-lived key is
    /// used directly. The short-lived `rt_*` client-session token exists
    /// because browsers cannot set this header; nothing here needs it.
    static func webSocketRequest(apiKey: String, model: String) -> URLRequest? {
        guard let url = webSocketURL(model: model) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The `session.update` frame. There is no language field in this protocol
    /// — Voxtral detects the language and reports it as
    /// `transcription.language` — so the app's language selection is not sent.
    static func sessionUpdatePayload(sampleRate: Int) -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "audio_format": [
                    "encoding": MistralVoxtralRealtime.encoding,
                    "sample_rate": sampleRate
                ],
                "target_streaming_delay_ms": MistralVoxtralRealtime.targetStreamingDelayMilliseconds
            ]
        ]
    }

    /// `sessionUpdatePayload` as sent: built from constants and integers, so
    /// it cannot fail to encode.
    static func sessionUpdateFrame(sampleRate: Int) -> String {
        let format = #"{"encoding":"\#(MistralVoxtralRealtime.encoding)","sample_rate":\#(sampleRate)}"#
        let delay = MistralVoxtralRealtime.targetStreamingDelayMilliseconds
        let session = #"{"audio_format":\#(format),"target_streaming_delay_ms":\#(delay)}"#
        return #"{"type":"session.update","session":\#(session)}"#
    }

    static let flushFrame = #"{"type":"input_audio.flush"}"#
    static let endFrame = #"{"type":"input_audio.end"}"#

    /// One `input_audio.append` frame. Base64 needs no JSON escaping, so the
    /// frame's length is known from the PCM length before it is encoded.
    static func appendFrame(for pcm: Data) -> String {
        #"{"type":"input_audio.append","audio":""# + pcm.base64EncodedString() + #""}"#
    }

    static let appendFrameWrapperBytes = appendFrame(for: Data()).utf8.count

    static func appendFrameByteCount(pcmBytes: Int) -> Int { appendFrameWrapperBytes + 4 * ((pcmBytes + 2) / 3) }

    /// The documented decoded cap, kept to whole PCM16 samples.
    static func sampleAlignedLimit(_ maximumBytes: Int) -> Int { max(maximumBytes - maximumBytes % 2, 2) }

    /// The append frames a chunk needs and their encoded bytes, from its
    /// length alone.
    static func appendCost(
        pcmBytes count: Int, maximumBytes: Int = MistralVoxtralRealtime.maximumAppendBytes
    ) -> (frames: Int, bytes: Int) {
        let limit = sampleAlignedLimit(maximumBytes)
        let whole = count / limit
        let rest = count % limit
        let restBytes = rest > 0 ? appendFrameByteCount(pcmBytes: rest) : 0
        return (whole + (rest > 0 ? 1 : 0), whole * appendFrameByteCount(pcmBytes: limit) + restBytes)
    }

    /// Splits PCM into slices no larger than the documented decoded cap, on
    /// sample boundaries. Chunking happens before base64 encoding, because the
    /// cap is on the decoded length.
    static func appendSlices(
        of audio: Data, maximumBytes: Int = MistralVoxtralRealtime.maximumAppendBytes
    ) -> [Data] {
        let limit = sampleAlignedLimit(maximumBytes)
        guard audio.count > limit else { return audio.isEmpty ? [] : [audio] }
        var slices: [Data] = []
        var offset = audio.startIndex
        while offset < audio.endIndex {
            let end = audio.index(offset, offsetBy: limit, limitedBy: audio.endIndex) ?? audio.endIndex
            slices.append(audio[offset..<end])
            offset = end
        }
        return slices
    }

    /// The `input_audio.append` payloads for `audio`, as the SDK models them.
    static func appendPayloads(
        for audio: Data, maximumBytes: Int = MistralVoxtralRealtime.maximumAppendBytes
    ) -> [[String: Any]] {
        appendSlices(of: audio, maximumBytes: maximumBytes).map {
            ["type": "input_audio.append", "audio": $0.base64EncodedString()]
        }
    }
}
