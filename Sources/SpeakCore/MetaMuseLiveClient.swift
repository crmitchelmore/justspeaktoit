// The client owns connection, handshake, reconnect and bounded finalisation
// alongside the frame decoding, which is what carries it past the file cap.
// swiftlint:disable file_length
import Foundation
import os

/// Cross-platform client for Meta Model API's dedicated realtime ASR endpoint.
public final class MetaMuseLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable { // swiftlint:disable:this type_body_length line_length
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    public let finishFlushesBufferedAudio = true

    private static let finishBudget: TimeInterval = 5
    private static let sendDrainBudget: TimeInterval = 1

    private let apiKey: String
    private let model: String
    private let language: String?
    private let keywords: [String]
    private let sampleRate: Int
    private let session: URLSession
    private let stateLock = NSLock()
    private let finishLock = NSLock()
    private let pendingSends = DispatchGroup()
    private let logger = SpeakLogger.logger(category: "MetaMuseLiveClient")

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isConfigured = false
    private var isStopping = false
    private var isFinishing = false
    private var reconnectAttempt = 0
    private var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    private var completedTurnIDs = Set<Int>()
    private var finishContinuation: CheckedContinuation<String?, Never>?

    let preroll: StreamingAudioPreroll

    public init(
        apiKey: String,
        model: String = MetaMuseVoiceTranscribe.modelID,
        language: String? = nil,
        keywords: [String] = [],
        sampleRate: Int = 24_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.language = language
        self.keywords = keywords
        self.sampleRate = sampleRate
        self.session = session
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard !apiKey.isEmpty else {
            onError(MetaMuseError.missingAPIKey)
            return
        }
        beginSession(onTranscript: onTranscript, onError: onError)
        connect()
    }

    /// Arms the callbacks and clears per-recording state without opening a
    /// socket. `start` is this plus `connect()`; tests pair it with `ingest` to
    /// drive the receive path offline.
    func beginSession(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            self.onTranscript = onTranscript
            self.onError = onError
            isConfigured = false
            isStopping = false
            isFinishing = false
            reconnectAttempt = 0
            accumulated.reset()
            completedTurnIDs = []
            finishContinuation = nil
        }
        preroll.reset()
    }

    /// Feeds one raw server frame through the receive path. The WebSocket loop
    /// is the only production caller; tests drive the client with it instead of
    /// opening a socket.
    func ingest(_ text: String) {
        handle(.string(text))
    }

    public func sendAudio(_ audioData: Data) {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard isConfigured, !isStopping, !isFinishing,
                  let task = webSocketTask, task.state == .running else {
                return nil
            }
            return task
        }
        guard let task else {
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
        guard let task else {
            stop()
            return fullTranscript()
        }

        let result = await awaitTrailingFinal { [weak self, weak task] in
            DispatchQueue.global().async {
                guard let self, let task else { return }
                self.flushPreroll(to: task)
                _ = self.pendingSends.wait(timeout: .now() + Self.sendDrainBudget)
                task.send(.string(#"{"type":"endStream"}"#)) { [weak self] error in
                    guard let self, let error, !WebSocketErrorFilter.shouldIgnore(error) else { return }
                    self.logger.error("Meta endStream send failed: \(error.localizedDescription)")
                    self.resolveFinish()
                }
            }
        }
        stop()
        return result
    }

    /// The bounded wait for the trailing `speechComplete`, resolved either by
    /// that event (the common case, one round trip) or by the finish budget.
    ///
    /// `whenArmed` runs once the waiter is installed, so a caller can put the
    /// `endStream` frame on the wire without racing its own completion handler;
    /// tests use it to deliver a final into an armed finish without a socket.
    func awaitTrailingFinal(
        budget: TimeInterval = MetaMuseLiveClient.finishBudget,
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
            isConfigured = false
            let task = webSocketTask
            webSocketTask = nil
            return task
        }
        preroll.reset()
        task?.cancel(with: .normalClosure, reason: nil)
        resolveFinish()
    }

    private func connect() {
        guard let url = Self.webSocketURL() else {
            currentOnError()?(MetaMuseError.invalidResponse)
            return
        }
        let task = session.webSocketTask(with: URLRequest(url: url))
        let published = withStateLock { () -> Bool in
            guard !isStopping, !isFinishing else { return false }
            isConfigured = false
            webSocketTask = task
            return true
        }
        guard published else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        task.resume()
        receiveMessages(on: task)
        do {
            let handshake = try Self.handshakeData(
                apiKey: apiKey,
                model: model,
                sampleRate: sampleRate,
                language: language,
                keywords: keywords
            )
            guard let text = String(data: handshake, encoding: .utf8) else {
                throw MetaMuseError.invalidResponse
            }
            task.send(.string(text)) { [weak self, weak task] error in
                guard let self, let task, let error else { return }
                self.handleTransportFailure(error, task: task)
            }
        } catch {
            // Keep a specific handshake failure (an unsupported capture rate,
            // say) legible instead of flattening it to "invalid response".
            currentOnError()?((error as? MetaMuseError) ?? MetaMuseError.invalidResponse)
            stop()
        }
    }

    private func receiveMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, self.isCurrent(task) else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                if self.isCurrent(task) { self.receiveMessages(on: task) }
            case .failure(let error):
                self.handleTransportFailure(error, task: task)
            }
        }
    }

    // Dispatches one server frame. Only an explicit `error` envelope tears the
    // session down: anything the client does not recognise — a non-JSON frame,
    // a frame with no `type`, a new envelope shape — is ignored, matching
    // Deepgram and Gemini, because a heartbeat or a field added upstream must
    // never end a live recording.
    //
    // Dispatch deliberately validates each documented envelope shape.
    // swiftlint:disable:next cyclomatic_complexity
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if object["type"] == nil, object["sessionId"] is String {
            withStateLock { isConfigured = true }
            if let task = currentTask() { flushPreroll(to: task) }
            return
        }
        guard let event = MetaMuseServerEvent(object: object) else { return }
        switch event {
        case .transcript(let text):
            currentOnTranscript()?(text, false)
        case .speechComplete(let turnID, let text):
            handleFinal(turnID: turnID, text: text)
        case .error(let message):
            fail(Self.error(fromServerMessage: message))
        case .lifecycle:
            break
        }
    }

    /// Folds a completed turn into the session transcript and releases a
    /// waiting `finishAndWait()` immediately, so a stop costs one round trip
    /// rather than the whole finish budget.
    private func handleFinal(turnID: Int, text: String) {
        let isNewTurn = withStateLock { () -> Bool in
            guard completedTurnIDs.insert(turnID).inserted else { return false }
            accumulated.append(final: text, eventID: String(turnID))
            return true
        }
        if resolveFinish() {
            // Trailing final consumed by finishAndWait(), which returns the
            // whole transcript; delivering it again through onTranscript would
            // double it for callers that append.
            return
        }
        if isNewTurn { currentOnTranscript()?(text, true) }
    }

    private func handleTransportFailure(_ error: Error, task: URLSessionWebSocketTask) {
        guard isCurrent(task) else { return }
        if isEnding {
            resolveFinish()
            return
        }
        let state = withStateLock { (isConfigured, reconnectAttempt) }
        let closeCode = Int(task.closeCode.rawValue)
        if Self.shouldReconnect(
            didHandshake: state.0,
            attempt: state.1,
            closeCode: closeCode == 0 ? nil : closeCode,
            isEnding: false
        ) {
            withStateLock {
                reconnectAttempt += 1
                webSocketTask = nil
                isConfigured = false
            }
            task.cancel(with: .goingAway, reason: nil)
            connect()
            return
        }
        fail(Self.error(closeCode: closeCode, reason: task.closeReason, fallback: error))
    }

    private func fail(_ error: Error) {
        let callback = withStateLock { () -> ((Error) -> Void)? in
            guard !isStopping else { return nil }
            isStopping = true
            isConfigured = false
            let callback = onError
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            return callback
        }
        callback?(error)
        resolveFinish()
    }

    private func send(_ audio: Data, on task: URLSessionWebSocketTask) {
        pendingSends.enter()
        task.send(.data(audio)) { [weak self] error in
            guard let self else { return }
            self.pendingSends.leave()
            if let error, !self.isEnding, !WebSocketErrorFilter.shouldIgnore(error) {
                self.handleTransportFailure(error, task: task)
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

    /// Whether the handshake has completed and the socket is accepting audio.
    var isSessionConfigured: Bool { withStateLock { isConfigured } }

    private var isEnding: Bool { withStateLock { isStopping || isFinishing } }
    private func isCurrent(_ task: URLSessionWebSocketTask) -> Bool {
        withStateLock { webSocketTask === task }
    }
    private func currentTask() -> URLSessionWebSocketTask? { withStateLock { webSocketTask } }
    private func currentOnTranscript() -> ((String, Bool) -> Void)? { withStateLock { onTranscript } }
    private func currentOnError() -> ((Error) -> Void)? { withStateLock { onError } }
    private func fullTranscript() -> String? { withStateLock { accumulated.transcriptOrNil } }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    static func webSocketURL(sessionID: String = UUID().uuidString) -> URL? {
        var components = URLComponents(url: MetaMuseVoiceTranscribe.realtimeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        return components?.url
    }

    static func handshakeData(
        apiKey: String,
        model: String,
        sampleRate: Int,
        language: String?,
        keywords: [String]
    ) throws -> Data {
        var object: [String: Any] = [
            "authorization": ["accessToken": "Bearer \(apiKey)"],
            "audioEncoding": try audioEncoding(forSampleRate: sampleRate),
            "model": model,
            "mode": MetaMuseMode.endpointing.rawValue,
            "partialMode": "CUMULATIVE",
            "emitAudioProgress": false
        ]
        let languageBias = MetaMuseVoiceTranscribe.languageBias(for: language)
        if !languageBias.isEmpty { object["languageBias"] = languageBias }
        if !keywords.isEmpty { object["keywords"] = keywords }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The realtime endpoint documents exactly two PCM encodings. Any other
    /// capture rate is a configuration error, not something to mislabel as
    /// 24 kHz — the server would transcribe resampled noise.
    static func audioEncoding(forSampleRate sampleRate: Int) throws -> String {
        switch sampleRate {
        case 16_000: return "PCM_16KHZ"
        case 24_000: return "PCM_24KHZ"
        default:
            throw MetaMuseError.invalidAudio(
                "Unsupported capture rate \(sampleRate) Hz; Muse Voice realtime accepts 16 kHz or 24 kHz."
            )
        }
    }

    static func shouldReconnect(
        didHandshake: Bool,
        attempt: Int,
        closeCode: Int?,
        isEnding: Bool
    ) -> Bool {
        guard !isEnding, !didHandshake, attempt == 0 else { return false }
        guard let closeCode else { return true }
        return closeCode == 1_011
    }

    static func error(fromServerMessage message: String) -> MetaMuseError {
        let lowered = message.lowercased()
        if lowered.contains("auth") || lowered.contains("token") || lowered.contains("credential") {
            return .authentication
        }
        if lowered.contains("rate") || lowered.contains("quota") || lowered.contains("concurrency") {
            return .rateLimited
        }
        if lowered.contains("backlog") || lowered.contains("real-time") || lowered.contains("realtime") {
            return .streamingPolicy(message)
        }
        return .unavailable(message)
    }

    static func error(closeCode: Int, reason: Data?, fallback: Error) -> MetaMuseError {
        let detail = reason.flatMap { String(data: $0, encoding: .utf8) }
            ?? fallback.localizedDescription
        switch closeCode {
        case 1_008: return .streamingPolicy(detail)
        case 1_013: return .rateLimited
        case 1_011: return .unavailable(detail)
        default: return .unavailable(detail)
        }
    }
}

enum MetaMuseServerEvent: Equatable {
    case transcript(String)
    case speechComplete(turnID: Int, transcript: String)
    case error(String)
    case lifecycle

    init?(object: [String: Any]) {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "transcript":
            guard let transcript = object["transcript"] as? String else { return nil }
            self = .transcript(transcript)
        case "speechComplete":
            guard let turnID = object["turnId"] as? Int,
                  let transcript = object["transcript"] as? String else { return nil }
            self = .speechComplete(turnID: turnID, transcript: transcript)
        case "error":
            guard let message = object["message"] as? String else { return nil }
            self = .error(message)
        case "speechStart", "speechEnd", "speaker", "audioProgress":
            self = .lifecycle
        default:
            self = .lifecycle
        }
    }
}
