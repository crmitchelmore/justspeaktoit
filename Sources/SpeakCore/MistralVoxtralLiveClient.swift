// The client owns connection, session configuration, base64 audio framing
// and bounded finalisation; the constants, errors and event decoding live
// in MistralVoxtralRealtime.swift.
// swiftlint:disable file_length
import Foundation

/// Cross-platform client for Mistral's Voxtral Realtime transcription socket.
///
/// Unlike every other provider here, audio is **base64 inside JSON text
/// frames** (`input_audio.append`), not binary frames. The service streams
/// append-only `transcription.text.delta` fragments and no per-utterance final;
/// the single authoritative transcript arrives as `transcription.done` after
/// `input_audio.flush` and `input_audio.end`. This client therefore folds the
/// deltas itself and reports cumulative interim text, so consumers see the same
/// shape they get from every other provider.
///
/// Audio captured before `session.created` is held in `StreamingAudioPreroll`
/// and replayed, because the session must be configured before any audio
/// (issue #641).
public final class MistralVoxtralLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable { // swiftlint:disable:this type_body_length line_length
    /// `transcription.done` restates the whole session, and it is the only
    /// final this service emits.
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    /// `input_audio.flush` commits audio Voxtral has received but not yet
    /// transcribed, so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true

    private static let sendDrainBudget: TimeInterval = 1

    private let apiKey: String
    private let model: String
    private let sampleRate: Int
    private let session: URLSession
    private let stateLock = NSLock()
    private let finishLock = NSLock()
    private let pendingSends = DispatchGroup()
    private let logger = SpeakLogger.logger(category: "MistralVoxtralLiveClient")

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isReady = false
    private var isStopping = false
    private var isFinishing = false
    /// The append-only deltas folded into the transcript so far. Voxtral emits
    /// fragments, so the running text is assembled here rather than by the
    /// consumer.
    private var streamedText = ""
    private var accumulated = TranscriptAccumulator(shape: .cumulativeTranscript)
    private var finishContinuation: CheckedContinuation<String?, Never>?

    let preroll: StreamingAudioPreroll
    let readiness = StreamingSessionReadiness()
    let sendBudget: StreamingAudioSendBudget

    public init(
        apiKey: String,
        model: String = MistralVoxtralRealtime.apiModelID,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.isEmpty ? MistralVoxtralRealtime.apiModelID : model
        self.sampleRate = sampleRate
        self.session = session
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        self.sendBudget = StreamingAudioSendBudget(sampleRate: sampleRate)
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard !apiKey.isEmpty else {
            onError(StreamingClientError.missingAPIKey(provider: "Mistral"))
            return
        }
        beginSession(onTranscript: onTranscript, onError: onError)
        connect()
    }

    /// Arms the callbacks and clears per-recording state without opening a
    /// socket. `start` is this plus `connect()`; tests pair it with `ingest`.
    func beginSession(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            self.onTranscript = onTranscript
            self.onError = onError
            isReady = false
            isStopping = false
            isFinishing = false
            streamedText = ""
            accumulated.reset()
            finishContinuation = nil
        }
        preroll.reset()
        readiness.reset()
        sendBudget.reset()
    }

    /// Feeds one raw server frame through the receive path. The WebSocket loop
    /// is the only production caller; tests drive the client with it.
    func ingest(_ text: String) {
        handle(.string(text))
    }

    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard isReady, !isStopping, !isFinishing,
                  let task = webSocketTask, task.state == .running else { return nil }
            return task
        }
        guard let task else {
            // The session must be created and configured before any audio, so
            // the user's opening words are held rather than dropped.
            if !isEnding { preroll.append(audioData) }
            return
        }
        send(audioData, on: task)
    }

    public func finishAndWait() async -> String? {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            isFinishing = true
            return webSocketTask
        }
        // No socket at all: there is nothing that could become ready.
        guard let task else {
            stop()
            return fullTranscript()
        }
        let result = await awaitFinalTranscript { [weak self, weak task] in
            DispatchQueue.global().async { [weak self, weak task] in
                guard let self, let task else { return }
                self.commitHeldCapture(to: task)
            }
        }
        stop()
        return result
    }

    /// Commits the held capture and closes the stream, waiting first for
    /// `session.created` if the session is still being set up.
    ///
    /// Finishing a short recording during setup used to drop the preroll
    /// entirely: `stop()` erased it and cancelled a socket that was about to
    /// be configured. The bounded wait lets the session finish configuring and
    /// flush that audio; a session that cannot be created inside the budget is
    /// still closed.
    private func commitHeldCapture(to task: URLSessionWebSocketTask) {
        guard readiness.waitUntilReady(), isCurrent(task) else {
            logger.error("Mistral realtime session was never created; finishing without a flush")
            resolveFinish()
            return
        }
        flushPreroll(to: task)
        _ = pendingSends.wait(timeout: .now() + Self.sendDrainBudget)
        // Flush first, then end: the order is what the SDK sends and
        // what its own tests assert.
        sendJSON(["type": "input_audio.flush"], on: task)
        sendJSON(["type": "input_audio.end"], on: task)
    }

    /// The bounded wait for `transcription.done`, resolved by that frame (the
    /// common case) or by the finish budget.
    ///
    /// `whenArmed` runs once the waiter is installed, so the flush/end frames
    /// cannot race their own completion handlers; tests use it to deliver
    /// frames into an armed finish without a socket.
    func awaitFinalTranscript(
        budget: TimeInterval = MistralVoxtralRealtime.finishBudget,
        whenArmed: () -> Void = {}
    ) async -> String? {
        await withCheckedContinuation { continuation in
            finishLock.lock()
            finishContinuation = continuation
            finishLock.unlock()

            whenArmed()

            DispatchQueue.global().asyncAfter(deadline: .now() + budget) { [weak self] in
                self?.resolveFinish()
            }
        }
    }

    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            isStopping = true
            isReady = false
            let task = webSocketTask
            webSocketTask = nil
            return task
        }
        preroll.reset()
        readiness.reset()
        sendBudget.reset()
        task?.cancel(with: .normalClosure, reason: nil)
        resolveFinish()
    }

    // MARK: - Protocol frames

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

    /// Splits PCM into `input_audio.append` payloads no larger than the
    /// documented decoded cap. Chunking happens before base64 encoding, because
    /// the cap is on the decoded length.
    static func appendPayloads(
        for audio: Data,
        maximumBytes: Int = MistralVoxtralRealtime.maximumAppendBytes
    ) -> [[String: Any]] {
        guard !audio.isEmpty else { return [] }
        let limit = max(maximumBytes, 1)
        var payloads: [[String: Any]] = []
        var offset = audio.startIndex
        while offset < audio.endIndex {
            let end = audio.index(offset, offsetBy: limit, limitedBy: audio.endIndex) ?? audio.endIndex
            payloads.append([
                "type": "input_audio.append",
                "audio": audio[offset..<end].base64EncodedString()
            ])
            offset = end
        }
        return payloads
    }

    // MARK: - Connection

    private func connect() {
        guard let url = Self.webSocketURL(model: model) else {
            currentOnError()?(StreamingClientError.invalidURL)
            return
        }
        var request = URLRequest(url: url)
        // A native app can set the handshake header, so the long-lived key is
        // used directly. The short-lived `rt_*` client-session token exists
        // because browsers cannot set this header; nothing here needs it.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        let published = withStateLock { () -> Bool in
            guard !isStopping, !isFinishing else { return false }
            isReady = false
            webSocketTask = task
            return true
        }
        guard published else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        task.resume()
        receiveMessages(on: task)
    }

    private func receiveMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, self.isCurrent(task) else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                if self.isCurrent(task) { self.receiveMessages(on: task) }
            case .failure(let error):
                self.handleTransportFailure(error)
            }
        }
    }

    /// Only an explicit `error` event ends the session; everything the app
    /// does not act on decodes to `nil` in `MistralRealtimeEvent` and is
    /// ignored, because an unrecognised frame must never end a recording.
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard let event = MistralRealtimeEvent(message: message) else { return }

        switch event {
        case .sessionCreated:
            handleSessionCreated()
        case .delta(let fragment):
            handleDelta(fragment)
        case .done(let text):
            handleDone(text: text)
        case .failure(let message, let code):
            // An error before `session.created` is a handshake rejection —
            // which is how a bad key or a blocked account arrives.
            let isHandshake = withStateLock { !isReady }
            fail(
                isHandshake
                    ? MistralRealtimeError.handshakeRejected(message: message)
                    : MistralRealtimeError.server(message: message, code: code)
            )
        }
    }

    private func handleSessionCreated() {
        guard let task = currentTask() else {
            withStateLock { isReady = true }
            readiness.markReady()
            return
        }
        sendJSON(Self.sessionUpdatePayload(sampleRate: sampleRate), on: task)
        withStateLock { isReady = true }
        readiness.markReady()
        flushPreroll(to: task)
    }

    /// Deltas are append-only fragments. Every other provider here reports
    /// cumulative interim text, so the folding happens on this side.
    private func handleDelta(_ fragment: String) {
        let running = withStateLock { () -> String in
            streamedText += fragment
            return streamedText
        }
        let trimmed = running.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentOnTranscript()?(trimmed, false)
    }

    /// `transcription.done` is authoritative for the whole session, so it
    /// replaces the folded deltas rather than extending them, and it releases a
    /// waiting `finishAndWait()` immediately.
    private func handleDone(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            withStateLock {
                streamedText = trimmed
                accumulated.replace(with: trimmed)
            }
        } else {
            // A done frame with no text still commits whatever the deltas built.
            withStateLock {
                let folded = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !folded.isEmpty { accumulated.replace(with: folded) }
            }
        }
        if resolveFinish() {
            // Consumed by finishAndWait(), which returns the whole transcript;
            // delivering it again would double it for callers that append.
            return
        }
        guard let final = fullTranscript() else { return }
        currentOnTranscript()?(final, true)
    }

    private func handleTransportFailure(_ error: Error) {
        if isEnding || WebSocketErrorFilter.shouldIgnore(error) {
            resolveFinish()
            return
        }
        fail(mapConnectionError(error))
    }

    private func fail(_ error: Error) {
        let callback = withStateLock { () -> ((Error) -> Void)? in
            guard !isStopping else { return nil }
            isStopping = true
            isReady = false
            let callback = onError
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            return callback
        }
        callback?(error)
        resolveFinish()
    }

    private func send(_ audio: Data, on task: URLSessionWebSocketTask) {
        // Each chunk becomes one or more base64 JSON frames, and every one is
        // retained until its send completes. A socket that has stopped
        // completing them would otherwise grow that backlog for the whole
        // recording, so each frame is admitted against a budget and a stalled
        // transport becomes a reported failure, which cancels the socket and
        // releases the work behind it.
        for payload in Self.appendPayloads(for: audio) {
            guard let json = Self.jsonString(payload) else { continue }
            let byteCount = json.utf8.count
            guard sendBudget.admit(byteCount) else {
                handleTransportFailure(StreamingClientError.transportStalled(provider: "Mistral"))
                return
            }
            sendFrame(json, on: task, releasing: byteCount)
        }
    }

    private static func jsonString(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func sendJSON(_ payload: [String: Any], on task: URLSessionWebSocketTask) {
        guard let json = Self.jsonString(payload) else { return }
        sendFrame(json, on: task, releasing: 0)
    }

    /// - Parameter releasing: Bytes reserved with `sendBudget` for this frame,
    ///   released when the send completes. Control frames reserve nothing.
    private func sendFrame(_ json: String, on task: URLSessionWebSocketTask, releasing byteCount: Int) {
        pendingSends.enter()
        task.send(.string(json)) { [weak self] error in
            guard let self else { return }
            if byteCount > 0 { self.sendBudget.release(byteCount) }
            self.pendingSends.leave()
            if let error, !self.isEnding, !WebSocketErrorFilter.shouldIgnore(error) {
                self.logger.error("Mistral realtime send failed: \(error.localizedDescription)")
                self.handleTransportFailure(error)
            }
        }
    }

    private func flushPreroll(to task: URLSessionWebSocketTask) {
        for chunk in preroll.drain() { send(chunk, on: task) }
    }

    @discardableResult
    private func resolveFinish() -> Bool {
        finishLock.lock()
        let continuation = finishContinuation
        finishContinuation = nil
        finishLock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: fullTranscript())
        return true
    }

    private func mapConnectionError(_ error: Error) -> Error {
        let description = (error as NSError).localizedDescription.lowercased()
        if description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Mistral")
        }
        return error
    }

    /// Whether `session.created` has arrived and the socket accepts audio.
    var isSessionReady: Bool { withStateLock { isReady } }

    private var isEnding: Bool { withStateLock { isStopping || isFinishing } }
    private func isCurrent(_ task: URLSessionWebSocketTask) -> Bool {
        withStateLock { webSocketTask === task }
    }
    private func currentTask() -> URLSessionWebSocketTask? { withStateLock { webSocketTask } }
    private func currentOnTranscript() -> ((String, Bool) -> Void)? { withStateLock { onTranscript } }
    private func currentOnError() -> ((Error) -> Void)? { withStateLock { onError } }

    /// The session transcript: the `transcription.done` text when it has
    /// arrived, otherwise the deltas folded so far — never `nil` merely because
    /// the terminal frame was lost.
    private func fullTranscript() -> String? {
        withStateLock {
            if let committed = accumulated.transcriptOrNil { return committed }
            let folded = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return folded.isEmpty ? nil : folded
        }
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
