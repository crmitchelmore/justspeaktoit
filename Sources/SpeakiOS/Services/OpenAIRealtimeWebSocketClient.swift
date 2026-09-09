import Foundation
import SpeakCore
import os.log

// swiftlint:disable file_length

// MARK: - Errors

public enum OpenAIRealtimeError: LocalizedError, Sendable {
    case missingAPIKey
    case preReadyAudioOverflow
    case connectionFailed(String)
    case sessionError(String)

    public var errorDescription: String? {
        switch self {
        case .preReadyAudioOverflow:
            return "Recording stopped because OpenAI startup took too long. Some audio was not sent; "
                + "the transcript may be incomplete."
        case .missingAPIKey:
            return "OpenAI API key is not configured."
        case .connectionFailed(let message):
            return "OpenAI Realtime connection failed: \(message)"
        case .sessionError(let message):
            return "OpenAI Realtime session error: \(message)"
        }
    }
}

// MARK: - WebSocket transport

/// Narrow transport seam: tests drive the production admission and parsed acknowledgement path.
protocol OpenAIRealtimeSocket: AnyObject, Sendable {
    var state: URLSessionTask.State { get }
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: OpenAIRealtimeSocket {}

// MARK: - WebSocket client

/// WebSocket client for the OpenAI Realtime API in transcription mode.
/// Off-MainActor; `@unchecked Sendable` with `NSLock` state guarding,
/// matching the macOS implementation.
final class OpenAIRealtimeWebSocketClient: @unchecked Sendable { // swiftlint:disable:this type_body_length
    enum Event {
        case sessionCreated
        case sessionReady
        case delta(String, itemId: String)
        case completed(String, itemId: String)
    }

    private enum AudioSendAction {
        case send(any OpenAIRealtimeSocket)
        case overflow(((Error) -> Void)?)
        case buffer
        case drop
    }

    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let makeSocket: (URLRequest) -> any OpenAIRealtimeSocket
    private let logger = SpeakLogger.logger(category: "OpenAIRealtimeWebSocket")
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()

    private var webSocketTask: (any OpenAIRealtimeSocket)?
    private var onEvent: ((Event) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false
    private var sessionReady: Bool = false
    private var isFlushingPreReadyAudio = false
    private var readyWaitTokens: [WaitToken] = []
    private var preReadyAudioBuffer: [Data] = []
    private var preReadyAudioBufferBytes: Int = 0
    private var didOverflow = false
    static let preReadyAudioByteLimit = 24_000 * 2 * 5 // 5s of 24 kHz PCM16

    init(
        apiKey: String, model: String, language: String?, sampleRate: Int,
        makeSocket: ((URLRequest) -> any OpenAIRealtimeSocket)? = nil
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        self.session = session
        self.makeSocket = makeSocket ?? { session.webSocketTask(with: $0) }
    }

    deinit {
        session.invalidateAndCancel()
    }

    func start(onEvent: @escaping (Event) -> Void, onError: @escaping (Error) -> Void) {
        withStateLock {
            isStopping = false
            sessionReady = false
            didOverflow = false
            isFlushingPreReadyAudio = false
            preReadyAudioBuffer = []
            preReadyAudioBufferBytes = 0
            self.onEvent = onEvent
            self.onError = onError
        }

        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            onError(OpenAIRealtimeError.connectionFailed("Invalid URL"))
            return
        }
        // All GA transcription models share the same `?intent=transcription`
        // URL with a unified `session.update` payload. The legacy
        // `?model=<name>` URL creates a realtime conversation session and
        // rejects transcription `session.update` events. The legacy
        // `OpenAI-Beta: realtime=v1` header pins the server to the old
        // schema and rejects `session.type`, so we omit it.
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        guard let url = components.url else {
            onError(OpenAIRealtimeError.connectionFailed("Invalid URL components"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = makeSocket(request)
        withStateLock { webSocketTask = task }
        task.resume()
        sendSessionUpdate()
        receiveMessages()
    }

    func stop() {
        let task: (any OpenAIRealtimeSocket)? = withStateLock {
            isStopping = true
            let snapshot = webSocketTask
            webSocketTask = nil
            preReadyAudioBuffer.removeAll()
            preReadyAudioBufferBytes = 0
            onEvent = nil
            onError = nil
            return snapshot
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Outbound

    private func sendSessionUpdate() {
        // turn_detection: null mirrors the macOS provider — push-to-talk
        // semantics. The shared builder also selects `languages` for the new
        // GPT transcription family and `language` for existing models.
        let payload = OpenAITranscriptionModels.realtimeSessionUpdatePayload(
            model: model,
            language: language,
            prompt: nil,
            sampleRate: sampleRate
        )
        sendJSON(payload)
    }

    func sendAudio(_ pcmData: Data) {
        let action: AudioSendAction = withStateLock {
            if isStopping || didOverflow || pcmData.isEmpty { return .drop }
            if !sessionReady {
                if preReadyAudioBufferBytes + pcmData.count <= Self.preReadyAudioByteLimit {
                    preReadyAudioBuffer.append(pcmData)
                    preReadyAudioBufferBytes += pcmData.count
                    return .buffer
                }
                // Keep the accepted prefix for normal finalisation, but admit no
                // more audio after a gap, even if the acknowledgement races us.
                didOverflow = true
                return .overflow(onError)
            }
            guard let task = webSocketTask, task.state == .running else {
                return .drop
            }
            return .send(task)
        }

        switch action {
        case .drop, .buffer:
            return
        case .overflow(let callback):
            logger.error(
                "OpenAI pre-ready audio overflow: limit=\(Self.preReadyAudioByteLimit) rejected=\(pcmData.count) bytes"
            )
            callback?(OpenAIRealtimeError.preReadyAudioOverflow)
        case .send(let task):
            sendJSONOnTask([
                "type": "input_audio_buffer.append",
                "audio": pcmData.base64EncodedString()
            ], task: task)
        }
    }

    var bufferedAudioBytes: Int { withStateLock { preReadyAudioBufferBytes } }

    func commitInputBuffer() {
        let task: (any OpenAIRealtimeSocket)? = withStateLock {
            guard !isStopping, let task = webSocketTask, task.state == .running else { return nil }
            return task
        }
        guard let task else { return }
        let payload: [String: Any] = ["type": "input_audio_buffer.commit"]
        sendJSONOnTask(payload, task: task)
    }

    func waitForPendingSends() async {
        await withCheckedContinuation { continuation in
            pendingSendGroup.notify(queue: .global()) {
                continuation.resume()
            }
        }
    }

    func awaitSessionReady(timeout: TimeInterval) async -> Bool {
        if withStateLock({ sessionReady && !isFlushingPreReadyAudio }) { return true }

        let token = WaitToken()
        let alreadyReady: Bool = withStateLock {
            if sessionReady && !isFlushingPreReadyAudio { return true }
            readyWaitTokens.append(token)
            return false
        }
        if alreadyReady { return true }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            token.signal(false)
        }
        return await token.wait()
    }

    private func flushPreReadyAudio() {
        let (task, frames): ((any OpenAIRealtimeSocket)?, [Data]) = withStateLock {
            let pending = preReadyAudioBuffer
            preReadyAudioBuffer = []
            preReadyAudioBufferBytes = 0
            return (webSocketTask, pending)
        }
        guard let task, task.state == .running, !frames.isEmpty else { return }
        logger.info("Flushing \(frames.count) pre-ready OpenAI Realtime audio frames")
        for frame in frames {
            let payload: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": frame.base64EncodedString()
            ]
            sendJSONOnTask(payload, task: task)
        }
    }

    private func sendJSON(_ payload: [String: Any]) {
        let task: (any OpenAIRealtimeSocket)? = withStateLock {
            guard !isStopping else { return nil }
            return webSocketTask
        }
        guard let task else { return }
        sendJSONOnTask(payload, task: task)
    }

    private func sendJSONOnTask(_ payload: [String: Any], task: any OpenAIRealtimeSocket) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            logger.error("Failed to serialize OpenAI Realtime payload: \(error.localizedDescription)")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode OpenAI Realtime payload as UTF-8")
            return
        }
        pendingSendGroup.enter()
        task.send(.string(text)) { [weak self] error in
            self?.pendingSendGroup.leave()
            if let error {
                self?.deliverError(error, task: task)
            }
        }
    }

    private func deliverError(_ error: Error, task: any OpenAIRealtimeSocket) {
        let isCurrent = withStateLock { !isStopping && webSocketTask === task }
        guard isCurrent else { return }
        currentOnError()?(error)
    }

    // MARK: Inbound

    private func receiveMessages() {
        guard let task = withStateLock({ webSocketTask }) else { return }
        task.receive { [weak self] result in
            guard let self,
                  self.withStateLock({ !self.isStopping && self.webSocketTask === task }) else { return }
            switch result {
            case .failure(let error):
                self.deliverError(error, task: task)
            case .success(let message):
                switch message {
                case .string(let text):
                    for outcome in OpenAIRealtimeEventParser.parse(text) {
                        self.dispatch(outcome)
                    }
                case .data:
                    break
                @unknown default:
                    break
                }
                self.receiveMessages()
            }
        }
    }

    private func dispatch(_ outcome: OpenAIRealtimeEventParser.ParsedOutcome) {
        switch outcome {
        case .event(let event):
            if case .sessionReady = event {
                let shouldFlush = withStateLock {
                    guard !isStopping, !sessionReady else { return false }
                    sessionReady = true
                    isFlushingPreReadyAudio = true
                    return true
                }
                guard shouldFlush else { return }
                flushPreReadyAudio()
                // Stop may observe readiness concurrently with the acknowledgement.
                // Do not release it until the accepted prefix has entered the send group.
                let tokensToFire: [WaitToken] = withStateLock {
                    isFlushingPreReadyAudio = false
                    let tokens = readyWaitTokens
                    readyWaitTokens.removeAll()
                    return tokens
                }
                for token in tokensToFire {
                    token.signal(true)
                }
            }
            currentOnEvent()?(event)
        case .error(let error):
            currentOnError()?(error)
        case .ignored:
            break
        }
    }

    @discardableResult
    private func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    private func currentOnEvent() -> ((Event) -> Void)? {
        withStateLock { onEvent }
    }

    private func currentOnError() -> ((Error) -> Void)? {
        withStateLock { onError }
    }
}

// MARK: - Event parser

/// Pure-function parser for OpenAI Realtime API JSON events. Module-private
/// so it doesn't collide with the macOS parser of the same name.
enum OpenAIRealtimeEventParser {
    enum ParsedOutcome {
        case event(OpenAIRealtimeWebSocketClient.Event)
        case error(Error)
        case ignored
    }

    static func parse(_ text: String) -> [ParsedOutcome] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return [.ignored]
        }

        switch type {
        case "transcription_session.created", "session.created":
            return [.event(.sessionCreated)]
        case "transcription_session.updated", "session.updated":
            return [.event(.sessionReady)]
        case "conversation.item.input_audio_transcription.delta":
            let itemId = (object["item_id"] as? String) ?? ""
            guard let delta = object["delta"] as? String, !delta.isEmpty else {
                return [.ignored]
            }
            return [.event(.delta(delta, itemId: itemId))]
        case "conversation.item.input_audio_transcription.completed":
            let itemId = (object["item_id"] as? String) ?? ""
            let transcript = (object["transcript"] as? String) ?? ""
            return [.event(.completed(transcript, itemId: itemId))]
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? (object["message"] as? String)
                ?? "Unknown OpenAI Realtime error"
            return [.error(OpenAIRealtimeError.sessionError(message))]
        default:
            return [.ignored]
        }
    }
}

// MARK: - WaitToken

/// One-shot async latch. The first `signal(_:)` resolves any pending
/// `wait()` and is idempotent thereafter. Mirrors the macOS implementation.
private final class WaitToken: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: Bool = false
    private var value: Bool = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal(_ value: Bool) {
        let cont: CheckedContinuation<Bool, Never>?
        let resolvedValue: Bool
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        self.value = value
        cont = continuation
        continuation = nil
        resolvedValue = value
        lock.unlock()
        cont?.resume(returning: resolvedValue)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if resolved {
                let resolvedValue = value
                lock.unlock()
                cont.resume(returning: resolvedValue)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}
