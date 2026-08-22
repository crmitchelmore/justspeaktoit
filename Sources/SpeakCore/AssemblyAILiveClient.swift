import Foundation
import os.log

// MARK: - AssemblyAI Live Client (Cross-platform WebSocket)

/// Cross-platform AssemblyAI Universal-3.5 Pro Streaming v3 client.
///
/// Shared by macOS and iOS. AssemblyAI emits incremental `Turn` frames (each
/// carrying the full running turn text) and one formatted end-of-turn frame.
/// This client folds the controller-side
/// turn assembly in: finalised turns are tracked by `turn_order`, combined with
/// the current interim, and emitted as a clean cumulative `(text, isFinal=false)`
/// so it can drive the generic iOS transcriber (which captures the latest text).
/// Conforms to ``StreamingTranscriptionClient``.
public final class AssemblyAILiveClient: StreamingTranscriptionClient, @unchecked Sendable {
    /// Final shape: this client emits a cumulative display string assembled from turns.
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript

    private static let beginTimeoutSeconds: Double = 8
    private static let terminationTimeoutSeconds: Double = 3
    private static let preBeginByteLimit = 16_000 * 2 * 5 // 5s of 16kHz PCM16
    private let apiKey: String
    private let speechModel: String
    private let sampleRate: Int
    private let session: URLSession
    private let logger = SpeakLogger.logger(category: "AssemblyAILiveClient")
    private let stateLock = NSLock()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping = false
    private var sessionDidBegin = false
    private var hasAttemptedHostFallback = false
    private var currentHost: AssemblyAIStreamingEndpoint = .global
    private var preBeginAudio: [Data] = []

    private var transcriptAssembler = AssemblyAIStreamingTranscriptAssembler()

    public init(
        apiKey: String,
        speechModel: String = AssemblyAIModels.universal35ProAPIName,
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
            currentHost = .europe
            preBeginAudio = []
            transcriptAssembler = AssemblyAIStreamingTranscriptAssembler()
            self.onTranscript = onTranscript
            self.onError = onError
        }
        // Connect to the EU host first and fall back to global on a pre-Begin
        // failure — this ordering is the more reliable one in practice.
        connect(using: .europe)
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
        // Terminate flushes in-flight audio. Keep receiving until the server's
        // final Termination frame; closing here would silently discard it.
        task.send(.string(#"{"type":"Terminate"}"#)) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.completeTermination(for: task)
                return
            }
            self.scheduleTerminationTimeout(for: task)
        }
    }

    private func scheduleTerminationTimeout(for task: URLSessionWebSocketTask) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationTimeoutSeconds) { [weak self, weak task] in
            guard let self, let task else { return }
            self.completeTermination(for: task)
        }
    }

    private func completeTermination(for task: URLSessionWebSocketTask) {
        let shouldClose = withStateLock { () -> Bool in
            guard webSocketTask === task else { return false }
            webSocketTask = nil
            return true
        }
        if shouldClose {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    // MARK: - Connection

    private func connect(using host: AssemblyAIStreamingEndpoint) {
        guard let url = AssemblyAIStreamingRequest.url(
            endpoint: host,
            apiKey: apiKey,
            sampleRate: sampleRate,
            speechModel: speechModel
        ) else {
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
            if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
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
                if WebSocketErrorFilter.shouldIgnore(error) {
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
        var fallback: AssemblyAIStreamingEndpoint = .global
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
            if let turn = try? JSONDecoder().decode(AssemblyAIStreamingTurn.self, from: data) {
                handleTurn(turn)
            }
        case "Begin":
            withStateLock { sessionDidBegin = true }
            flushPreBeginAudio()
        case "Termination":
            if let task = currentWebSocketTask() {
                completeTermination(for: task)
            }
        default:
            break
        }
    }

    private func handleTurn(_ turn: AssemblyAIStreamingTurn) {
        guard let update = withStateLock({ transcriptAssembler.consume(turn) }) else { return }
        // This client emits a cumulative display string rather than per-turn
        // deltas, so the generic iOS wrapper must replace its text in both cases.
        currentOnTranscript()?(update.displayText, false)
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

struct AssemblyAIStreamingTurn: Decodable {
    let turn_order: Int // swiftlint:disable:this identifier_name
    let turn_is_formatted: Bool // swiftlint:disable:this identifier_name
    let end_of_turn: Bool // swiftlint:disable:this identifier_name
    let transcript: String
}

struct AssemblyAIStreamingTranscriptUpdate: Equatable {
    let displayText: String
    let finalizedTurn: Bool
}

struct AssemblyAIStreamingTranscriptAssembler {
    private var finalTexts: [String] = []
    private var finalIndexByTurnOrder: [Int: Int] = [:]
    private var fullTranscript = ""
    private var currentInterim = ""

    mutating func consume(_ turn: AssemblyAIStreamingTurn) -> AssemblyAIStreamingTranscriptUpdate? {
        guard !turn.transcript.isEmpty || turn.end_of_turn else { return nil }

        let finalized = turn.end_of_turn && turn.turn_is_formatted
        if finalized {
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
        } else {
            currentInterim = turn.transcript
        }

        let display = fullTranscript.isEmpty ? currentInterim
            : (currentInterim.isEmpty ? fullTranscript : fullTranscript + " " + currentInterim)
        return AssemblyAIStreamingTranscriptUpdate(displayText: display, finalizedTurn: finalized)
    }
}
