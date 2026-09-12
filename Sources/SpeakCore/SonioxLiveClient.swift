import Foundation
import os.log

// MARK: - Soniox Live Client (Cross-platform WebSocket)

/// Cross-platform Soniox real-time speech-to-text client.
public final class SonioxLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    public var finishFlushesBufferedAudio: Bool { true }

    struct Timing: Sendable {
        let overall: TimeInterval
        static let production = Timing(overall: 3)
    }

    private struct Outbound {
        let message: URLSessionWebSocketTask.Message
        let audioBytes: Int
        let makesReady: Bool
    }

    private final class Run: @unchecked Sendable {
        let id = UUID()
        let socket: LiveWebSocketTransport
        let onTranscript: (String, Bool) -> Void
        let onError: (Error) -> Void
        var ready = false
        var finishing = false
        var completed = false
        var sending = false
        var controlsQueued = false
        var outbound: [Outbound] = []
        var waiters: [CheckedContinuation<String?, Never>] = []
        var accumulatedFinalText = ""
        var finalVersion = 0
        var deliveredFinalVersion = 0
        let sendBudget: StreamingAudioSendBudget

        init(
            socket: LiveWebSocketTransport,
            sampleRate: Int,
            onTranscript: @escaping (String, Bool) -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.socket = socket
            self.sendBudget = StreamingAudioSendBudget(sampleRate: sampleRate)
            self.onTranscript = onTranscript
            self.onError = onError
        }
    }

    private static let websocketHost = "stt-rt.soniox.com"
    private static let websocketPath = "/transcribe-websocket"
    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let socketFactory: LiveWebSocketFactory
    private let timing: Timing
    private let logger = SpeakLogger.logger(category: "SonioxLiveClient")
    private let queue = DispatchQueue(label: "SonioxLiveClient.session")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let callbackQueue = DispatchQueue(label: "SonioxLiveClient.callbacks")
    private var run: Run?
    private var lastTranscript: String?
    private var callbackRunID: UUID?
    private var acceptsPrestartAudio = true
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
        self.socketFactory = { request in
            URLSessionLiveWebSocketTransport(task: session.webSocketTask(with: request))
        }
        self.timing = .production
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    init(
        apiKey: String,
        model: String = "stt-rt-v5",
        language: String? = nil,
        sampleRate: Int = 16_000,
        timing: Timing,
        socketFactory: @escaping LiveWebSocketFactory
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.socketFactory = socketFactory
        self.timing = timing
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    func makeRequest() -> URLRequest? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = Self.websocketHost
        components.path = Self.websocketPath
        return components.url.map { URLRequest(url: $0) }
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard let request = makeRequest() else {
            onError(StreamingClientError.invalidURL)
            return
        }
        let socket = socketFactory(request)
        queue.async { [weak self] in
            guard let self else { return }
            if let previous = self.run { self.complete(previous, closeCode: .goingAway) }
            self.lastTranscript = nil
            self.acceptsPrestartAudio = false
            self.preroll.reset()
            let current = Run(
                socket: socket, sampleRate: self.sampleRate,
                onTranscript: onTranscript, onError: onError
            )
            self.run = current
            self.callbackRunID = current.id
            socket.resume()
            guard let config = self.initialConfigurationMessage() else {
                self.emitError(StreamingClientError.invalidURL, on: current)
                self.complete(current, closeCode: .goingAway)
                return
            }
            current.outbound.append(Outbound(message: config, audioBytes: 0, makesReady: true))
            self.pump(current)
            self.receive(on: current)
            self.logger.info("Soniox WebSocket connecting (model=\(self.model, privacy: .public))")
        }
    }

    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        withQueueLock {
            guard let current = run else {
                if acceptsPrestartAudio { preroll.append(audioData) }
                return
            }
            guard !current.finishing, !current.completed else { return }
            guard current.ready else {
                preroll.append(audioData)
                return
            }
            enqueueAudio(audioData, on: current)
        }
    }

    public func finishAndWait() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let current = self.run else {
                    continuation.resume(returning: self?.lastTranscript)
                    return
                }
                guard !current.completed else {
                    continuation.resume(returning: self.transcript(current))
                    return
                }
                current.waiters.append(continuation)
                if current.socket.state == .completed || current.socket.state == .canceling {
                    self.complete(current, closeCode: .normalClosure)
                    return
                }
                guard !current.finishing else { return }
                current.finishing = true
                self.queue.asyncAfter(deadline: .now() + self.timing.overall) { [weak self, weak current] in
                    guard let self, let current, self.isActive(current) else { return }
                    self.complete(current, closeCode: .normalClosure)
                }
                if current.ready { self.enqueueFinishControls(on: current) }
            }
        }
    }

    /// Immediate abort. Graceful callers use `finishAndWait()`.
    public func stop() {
        withQueueLock {
            acceptsPrestartAudio = false
            guard let current = run else {
                preroll.reset()
                return
            }
            complete(current, closeCode: .normalClosure)
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            run?.socket.cancel(with: .goingAway, reason: nil)
        } else {
            queue.sync { run?.socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    private func initialConfigurationMessage() -> URLSessionWebSocketTask.Message? {
        var payload: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": 1
        ]
        if let language { payload["language_hints"] = [language.localeLanguageCode] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return .string(text)
    }

    private func receive(on current: Run) {
        current.socket.receive { [weak self, weak current] result in
            guard let self, let current else { return }
            self.queue.async {
                guard self.isActive(current) else { return }
                switch result {
                case .success(let message):
                    self.handle(message, on: current)
                    if self.isActive(current) { self.receive(on: current) }
                case .failure(let error):
                    if !WebSocketErrorFilter.shouldIgnore(error) {
                        self.emitError(self.mapConnectionError(error), on: current)
                    }
                    self.complete(current, closeCode: .goingAway)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, on current: Run) {
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text,
              let data = text.data(using: .utf8),
              let response = try? JSONDecoder().decode(SonioxStreamResponse.self, from: data) else { return }

        if let code = response.errorCode {
            let message = response.errorMessage ?? "Soniox error \(code)"
            emitError(NSError(domain: "Soniox", code: code,
                              userInfo: [NSLocalizedDescriptionKey: message]), on: current)
            complete(current, closeCode: .goingAway)
            return
        }

        var newFinals = ""
        var nonFinals = ""
        var sawMarker = false
        for token in response.tokens ?? [] {
            if token.text == "<fin>" || token.text == "<end>" {
                sawMarker = true
            } else if token.isFinal == true {
                newFinals.append(token.text)
            } else {
                nonFinals.append(token.text)
            }
        }
        if !newFinals.isEmpty {
            current.accumulatedFinalText.append(newFinals)
            current.finalVersion += 1
        }

        let display = (current.accumulatedFinalText + nonFinals)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty && response.tokens?.isEmpty == false {
            emitTranscript(display, isFinal: false, on: current)
        }

        if (sawMarker || response.finished == true), !current.finishing,
           current.finalVersion > current.deliveredFinalVersion,
           let final = transcript(current) {
            current.deliveredFinalVersion = current.finalVersion
            emitTranscript(final, isFinal: true, on: current)
        }
        if response.finished == true { complete(current, closeCode: .normalClosure) }
    }

    /// Fixture entry point for the real provider decoder.
    func parseResponse(_ json: String) {
        queue.sync {
            if let current = run { handle(.string(json), on: current) }
        }
    }

    private func enqueueAudio(_ data: Data, on current: Run) {
        guard current.sendBudget.admit(data.count) else {
            emitError(StreamingClientError.transportStalled(provider: "Soniox"), on: current)
            complete(current, closeCode: .goingAway)
            return
        }
        current.outbound.append(Outbound(message: .data(data), audioBytes: data.count, makesReady: false))
        pump(current)
    }

    private func enqueueFinishControls(on current: Run) {
        guard !current.controlsQueued else { return }
        current.controlsQueued = true
        for chunk in preroll.drain() { enqueueAudio(chunk, on: current) }
        current.outbound.append(Outbound(message: .string(#"{"type":"finalize"}"#), audioBytes: 0, makesReady: false))
        current.outbound.append(Outbound(message: .data(Data()), audioBytes: 0, makesReady: false))
        pump(current)
    }

    private func pump(_ current: Run) {
        guard isActive(current), !current.sending, !current.outbound.isEmpty else { return }
        current.sending = true
        let outbound = current.outbound.removeFirst()
        current.socket.send(outbound.message) { [weak self, weak current] error in
            guard let self, let current else { return }
            self.queue.async {
                guard self.isActive(current) else { return }
                current.sendBudget.release(outbound.audioBytes)
                current.sending = false
                if let error {
                    self.emitError(error, on: current)
                    self.complete(current, closeCode: .goingAway)
                    return
                }
                if outbound.makesReady {
                    current.ready = true
                    for chunk in self.preroll.drain() { self.enqueueAudio(chunk, on: current) }
                    if current.finishing { self.enqueueFinishControls(on: current) }
                }
                self.pump(current)
            }
        }
    }

    private func complete(_ current: Run, closeCode: URLSessionWebSocketTask.CloseCode) {
        guard !current.completed else { return }
        current.completed = true
        if run === current { run = nil }
        preroll.reset()
        current.socket.cancel(with: closeCode, reason: nil)
        let result = transcript(current)
        lastTranscript = result
        acceptsPrestartAudio = false
        let waiters = current.waiters
        current.waiters = []
        waiters.forEach { $0.resume(returning: result) }
    }

    private func transcript(_ current: Run) -> String? {
        let value = current.accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isActive(_ current: Run) -> Bool { run === current && !current.completed }

    private func withQueueLock<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return operation() }
        return queue.sync(execute: operation)
    }

    private func emitTranscript(_ text: String, isFinal: Bool, on current: Run) {
        let id = current.id
        let callback = current.onTranscript
        callbackQueue.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.callbackRunID == id }) else { return }
            callback(text, isFinal)
        }
    }

    private func emitError(_ error: Error, on current: Run) {
        let id = current.id
        let callback = current.onError
        callbackQueue.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.callbackRunID == id }) else { return }
            callback(error)
        }
    }

    private func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403 || description.contains("unauthorized")
            || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Soniox")
        }
        return error
    }
}

private struct SonioxStreamResponse: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

private struct SonioxToken: Decodable {
    let text: String
    let isFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}
