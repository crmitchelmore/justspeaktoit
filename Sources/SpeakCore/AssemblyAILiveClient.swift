import Foundation
import os.log

// MARK: - AssemblyAI Live Client (Cross-platform WebSocket)

/// Cross-platform AssemblyAI Universal-Streaming v3 client.
///
/// Shared by macOS and iOS. AssemblyAI emits incremental `Turn` frames (each
/// carrying the full running turn text) and, with `format_turns=true`, a
/// second *formatted* end-of-turn frame. This client folds the controller-side
/// turn assembly in: finalised turns are tracked by `turn_order`, combined with
/// the current interim, and emitted as a clean cumulative `(text, isFinal=false)`
/// so it can drive the generic iOS transcriber (which captures the latest text).
/// Conforms to ``StreamingTranscriptionClient``.
public final class AssemblyAILiveClient: StreamingTranscriptionClient, @unchecked Sendable {
    // swiftlint:disable:previous type_body_length
    private enum Host: String {
        case global = "streaming.assemblyai.com"
        case europe = "streaming.eu.assemblyai.com"
    }

    private static let beginTimeoutSeconds: Double = 8
    private static let preBeginByteLimit = 16_000 * 2 * 5 // 5s of 16kHz PCM16
    private static let minTurnSilenceMs = "560"

    private let apiKey: String
    private let speechModel: String
    private let sampleRate: Int
    private let session: URLSession
    private let logger = Logger(subsystem: "com.justspeaktoit", category: "AssemblyAILiveClient")
    private let stateLock = NSLock()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping = false
    private var sessionDidBegin = false
    private var hasAttemptedHostFallback = false
    private var currentHost: Host = .global
    private var preBeginAudio: [Data] = []

    // Turn assembly state.
    private var finalTexts: [String] = []
    private var finalIndexByTurnOrder: [Int: Int] = [:]
    private var fullTranscript = ""
    private var currentInterim = ""

    public init(
        apiKey: String,
        speechModel: String = "u3-rt-pro",
        sampleRate: Int = 16_000,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speechModel = speechModel
        self.sampleRate = sampleRate
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            isStopping = false
            sessionDidBegin = false
            hasAttemptedHostFallback = false
            currentHost = .global
            preBeginAudio = []
            finalTexts = []
            finalIndexByTurnOrder = [:]
            fullTranscript = ""
            currentInterim = ""
            self.onTranscript = onTranscript
            self.onError = onError
        }
        connect(using: .global)
    }

    public func sendAudio(_ audioData: Data) {
        let (task, didBegin) = withStateLock { (webSocketTask, sessionDidBegin) }
        guard let task, task.state == .running, didBegin else {
            withStateLock {
                preBeginAudio.append(audioData)
                var total = preBeginAudio.reduce(0) { $0 + $1.count }
                while total > Self.preBeginByteLimit, !preBeginAudio.isEmpty {
                    total -= preBeginAudio.removeFirst().count
                }
            }
            return
        }
        send(audioData, on: task)
    }

    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            return webSocketTask
        }
        guard let task, task.state == .running else { return }
        // Flush the in-flight turn, then terminate after a brief safety delay.
        task.send(.string(#"{"type":"ForceEndpoint"}"#)) { [weak self] _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) {
                task.send(.string(#"{"type":"Terminate"}"#)) { _ in }
                task.cancel(with: .normalClosure, reason: nil)
                self?.withStateLock {
                    if self?.webSocketTask === task { self?.webSocketTask = nil }
                }
            }
        }
    }

    // MARK: - Connection

    private func connect(using host: Host) {
        var components = URLComponents(string: "wss://\(host.rawValue)/v3/ws")
        components?.queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "speech_model", value: speechModel),
            URLQueryItem(name: "min_turn_silence", value: Self.minTurnSilenceMs),
            URLQueryItem(name: "token", value: apiKey)
        ]
        guard let url = components?.url else {
            currentOnError()?(StreamingClientError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        let proceed = withStateLock { () -> Bool in
            guard !isStopping else { return false }
            currentHost = host
            webSocketTask = task
            return true
        }
        guard proceed else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        task.resume()
        receiveMessages()
        scheduleBeginTimeout(for: task)
    }

    private func scheduleBeginTimeout(for task: URLSessionWebSocketTask) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.beginTimeoutSeconds) { [weak self, weak task] in
            guard let self, let task else { return }
            let fire = self.withStateLock { () -> Bool in
                guard !self.sessionDidBegin, !self.isStopping, self.webSocketTask === task else { return false }
                self.isStopping = true
                return true
            }
            guard fire else { return }
            task.cancel(with: .goingAway, reason: nil)
            self.currentOnError()?(NSError(
                domain: "AssemblyAI", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AssemblyAI session did not start (Begin timeout)."]
            ))
        }
    }

    private func send(_ audioData: Data, on task: URLSessionWebSocketTask) {
        task.send(.data(audioData)) { [weak self] error in
            guard let self, let error else { return }
            if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
            self.currentOnError()?(error)
        }
    }

    private func flushPreBeginAudio() {
        let (task, frames) = withStateLock { () -> (URLSessionWebSocketTask?, [Data]) in
            let pending = preBeginAudio
            preBeginAudio = []
            return (webSocketTask, pending)
        }
        guard let task, task.state == .running else { return }
        for frame in frames { send(frame, on: task) }
    }

    private func receiveMessages() {
        guard let task = currentWebSocketTask() else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessages()
            case .failure(let error):
                if self.isStoppingState() { return }
                // Spurious ENOTCONN around the handshake: re-arm instead of failing.
                if self.shouldIgnoreSocketError(error) {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        self?.receiveMessages()
                    }
                    return
                }
                if self.retryWithFallbackIfNeeded(after: error) { return }
                self.currentOnError()?(error)
            }
        }
    }

    private func retryWithFallbackIfNeeded(after error: Error) -> Bool {
        var taskToCancel: URLSessionWebSocketTask?
        var fallback: Host = .global
        let shouldRetry = withStateLock { () -> Bool in
            guard !isStopping, !hasAttemptedHostFallback, !sessionDidBegin else { return false }
            hasAttemptedHostFallback = true
            fallback = (currentHost == .europe) ? .global : .europe
            taskToCancel = webSocketTask
            webSocketTask = nil
            return true
        }
        guard shouldRetry else { return false }
        taskToCancel?.cancel(with: .goingAway, reason: nil)
        connect(using: fallback)
        return true
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) { parseResponse(text) }
        @unknown default:
            break
        }
    }

    private func parseResponse(_ json: String) {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AssemblyAIEnvelope.self, from: data) else {
            return
        }
        let type = envelope.type ?? (envelope.turn_order != nil ? "Turn" : "")
        switch type {
        case "Turn":
            if let turn = try? JSONDecoder().decode(AssemblyAITurn.self, from: data) {
                handleTurn(turn)
            }
        case "Begin":
            withStateLock { sessionDidBegin = true }
            flushPreBeginAudio()
        case "Termination":
            withStateLock { isStopping = true }
        default:
            break
        }
    }

    private func handleTurn(_ turn: AssemblyAITurn) {
        guard !turn.transcript.isEmpty || turn.end_of_turn else { return }

        if turn.end_of_turn {
            if !turn.turn_is_formatted {
                // Unformatted end-of-turn: show as interim; formatted version follows.
                withStateLock { currentInterim = turn.transcript }
                emitDisplay()
                return
            }
            withStateLock {
                if let existing = finalIndexByTurnOrder[turn.turn_order], finalTexts.indices.contains(existing) {
                    finalTexts[existing] = turn.transcript
                    fullTranscript = finalTexts.joined(separator: " ")
                } else {
                    finalTexts.append(turn.transcript)
                    finalIndexByTurnOrder[turn.turn_order] = finalTexts.count - 1
                    fullTranscript = fullTranscript.isEmpty
                        ? turn.transcript
                        : fullTranscript + " " + turn.transcript
                }
                currentInterim = ""
            }
            emitDisplay()
        } else {
            withStateLock { currentInterim = turn.transcript }
            emitDisplay()
        }
    }

    private func emitDisplay() {
        let display = withStateLock { () -> String in
            fullTranscript.isEmpty ? currentInterim
                : (currentInterim.isEmpty ? fullTranscript : fullTranscript + " " + currentInterim)
        }
        currentOnTranscript()?(display, false)
    }

    private func shouldIgnoreSocketError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true }
        if nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
            return true
        }
        return false
    }

    private func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    private func currentWebSocketTask() -> URLSessionWebSocketTask? { withStateLock { webSocketTask } }
    private func isStoppingState() -> Bool { withStateLock { isStopping } }
    private func currentOnTranscript() -> ((String, Bool) -> Void)? { withStateLock { onTranscript } }
    private func currentOnError() -> ((Error) -> Void)? { withStateLock { onError } }
}

private struct AssemblyAIEnvelope: Decodable {
    let type: String?
    let turn_order: Int? // swiftlint:disable:this identifier_name
}

private struct AssemblyAITurn: Decodable {
    let turn_order: Int // swiftlint:disable:this identifier_name
    let turn_is_formatted: Bool // swiftlint:disable:this identifier_name
    let end_of_turn: Bool // swiftlint:disable:this identifier_name
    let transcript: String
}
