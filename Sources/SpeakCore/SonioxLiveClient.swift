import Foundation
import os.log

// MARK: - Soniox Live Client (Cross-platform WebSocket)

/// Cross-platform Soniox real-time speech-to-text client.
///
/// Shared by macOS and iOS. Soniox streams token batches; final tokens are
/// accumulated so the live transcript grows monotonically, and the cumulative
/// final is committed on the `finished`/finalize markers. Conforms to
/// ``StreamingTranscriptionClient``.
public final class SonioxLiveClient: StreamingTranscriptionClient, @unchecked Sendable {
    private static let websocketHost = "stt-rt.soniox.com"
    private static let websocketPath = "/transcribe-websocket"

    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let logger = SpeakLogger.logger(category: "SonioxLiveClient")
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()
    /// Upper bound on how long a close waits for queued frames to reach the
    /// transport; a wedged send must never leave the socket open forever.
    private static let stopFlushBudget: DispatchTimeInterval = .milliseconds(750)

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping = false
    private var accumulatedFinalText = ""

    /// Holds audio captured between the recording cue and the socket reaching
    /// `.running`, then replays it in order (issue #641).
    let preroll: StreamingAudioPreroll

    public init(
        apiKey: String,
        model: String = "stt-rt-v5",
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.session = session
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            isStopping = false
            accumulatedFinalText = ""
            self.onTranscript = onTranscript
            self.onError = onError
        }
        preroll.reset()
        connectWebSocket()
    }

    /// Sends raw PCM Int16 audio data to Soniox.
    ///
    /// Audio captured before the socket is running is parked in the pre-roll
    /// buffer and replayed, in order, on the first send that finds a live
    /// transport — so speech that starts with the cue is never dropped.
    public func sendAudio(_ audioData: Data) {
        guard let task = currentWebSocketTask(), task.state == .running else {
            guard !isStoppingState() else { return }
            preroll.append(audioData)
            return
        }
        for chunk in drainPreroll() {
            transmit(chunk, on: task)
        }
        transmit(audioData, on: task)
    }

    private func drainPreroll() -> [Data] {
        let held = preroll.drain()
        guard !held.isEmpty else { return held }
        let bytes = held.reduce(0) { $0 + $1.count }
        let leadingMilliseconds = Int((Double(bytes) / 2.0 / Double(max(sampleRate, 1))) * 1000)
        logger.info(
            "Soniox: replaying \(held.count) pre-roll chunks (\(leadingMilliseconds) ms of leading audio)"
        )
        return held
    }

    private func transmit(_ audioData: Data, on task: URLSessionWebSocketTask) {
        transmit(.data(audioData), on: task)
    }

    /// Every frame — audio, replayed pre-roll and the finalize handshake — goes
    /// through here so `stop()` can wait for the transport to take them before
    /// cancelling the socket.
    private func transmit(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(message) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self, let error else { return }
            if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
            self.currentOnError()?(error)
        }
    }

    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            return webSocketTask
        }
        guard let task else {
            preroll.reset()
            return
        }

        // Best-effort finalize: ask Soniox to commit in-flight tokens and flush
        // before closing so trailing words aren't lost.
        if task.state == .running {
            for chunk in drainPreroll() {
                transmit(chunk, on: task)
            }
            transmit(.string(#"{"type":"finalize"}"#), on: task)
            transmit(.data(Data()), on: task)
        }

        let unsentPreroll = preroll.snapshot
        if unsentPreroll.byteCount > 0 {
            logger.warning(
                "Soniox: discarding \(unsentPreroll.chunkCount) pre-roll chunks — transport never became ready"
            )
        }
        preroll.reset()
        closeAfterPendingSends(task)
    }

    /// `cancel(with:reason:)` fails whatever URLSession has not yet handed to
    /// the network, so the close waits (bounded) for the replayed pre-roll and
    /// the finalize frames to land before the socket goes away.
    private func closeAfterPendingSends(_ task: URLSessionWebSocketTask) {
        let sendGroup = pendingSendGroup
        let logger = self.logger
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if sendGroup.wait(timeout: .now() + Self.stopFlushBudget) == .timedOut {
                logger.warning("Soniox: closing with sends still in flight after the stop flush budget")
            }
            if task.state == .running {
                task.cancel(with: .normalClosure, reason: nil)
            }
            self?.clearWebSocketTask(task)
        }
    }

    /// Only the task this stop owns may be cleared: a newer session may already
    /// have published its own socket.
    private func clearWebSocketTask(_ task: URLSessionWebSocketTask) {
        withStateLock {
            if webSocketTask === task { webSocketTask = nil }
        }
    }
}

// MARK: - Private

private extension SonioxLiveClient {
    func connectWebSocket() {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = Self.websocketHost
        components.path = Self.websocketPath
        guard let url = components.url else {
            currentOnError()?(StreamingClientError.invalidURL)
            return
        }

        let task = session.webSocketTask(with: url)
        let proceed = withStateLock { () -> Bool in
            guard !isStopping else { return false }
            webSocketTask = task
            task.resume()
            return true
        }
        guard proceed else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }

        sendInitialConfig()
        logger.info("Soniox WebSocket connecting (model=\(self.model, privacy: .public))")
        receiveMessages()
    }

    func sendInitialConfig() {
        guard let task = currentWebSocketTask() else { return }
        var payload: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": 1
        ]
        if let language {
            payload["language_hints"] = [language.localeLanguageCode]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.string(json)) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self, let error, !self.isStoppingState() else { return }
            self.currentOnError()?(error)
        }
    }

    func receiveMessages() {
        guard let task = currentWebSocketTask() else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessages()
            case .failure(let error):
                if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
                self.currentOnError()?(self.mapConnectionError(error))
            }
        }
    }

    func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) { parseResponse(text) }
        @unknown default:
            break
        }
    }

    func parseResponse(_ json: String) {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(SonioxStreamResponse.self, from: data) else {
            return
        }

        if let code = response.errorCode {
            let message = response.errorMessage ?? "Soniox error \(code)"
            currentOnError()?(NSError(domain: "Soniox", code: code,
                                      userInfo: [NSLocalizedDescriptionKey: message]))
            return
        }

        let tokens = response.tokens ?? []
        if !tokens.isEmpty {
            var newFinals = ""
            var nonFinals = ""
            var sawFinalizationMarker = false
            for token in tokens {
                // `<fin>` acknowledges a manual finalize; `<end>` marks session end.
                if token.text == "<fin>" || token.text == "<end>" {
                    sawFinalizationMarker = true
                    continue
                }
                if token.isFinal == true {
                    newFinals.append(token.text)
                } else {
                    nonFinals.append(token.text)
                }
            }

            let display: String = withStateLock {
                accumulatedFinalText.append(newFinals)
                return accumulatedFinalText + nonFinals
            }
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                currentOnTranscript()?(trimmed, false)
            }

            if sawFinalizationMarker { flushFinal() }
        }

        if response.finished == true { flushFinal() }
    }

    func flushFinal() {
        let text: String? = withStateLock {
            let snapshot = accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
            return snapshot.isEmpty ? nil : snapshot
        }
        if let text { currentOnTranscript()?(text, true) }
    }

    func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Soniox")
        }
        return error
    }

    func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    func currentWebSocketTask() -> URLSessionWebSocketTask? { withStateLock { webSocketTask } }
    func isStoppingState() -> Bool { withStateLock { isStopping } }
    func currentOnTranscript() -> ((String, Bool) -> Void)? { withStateLock { onTranscript } }
    func currentOnError() -> ((Error) -> Void)? { withStateLock { onError } }
}

private struct SonioxStreamResponse: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: Int?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

private struct SonioxToken: Decodable {
    let text: String
    let isFinal: Bool?

    private enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}
