import Foundation
import os.log

// MARK: - Cartesia Live Client (Cross-platform WebSocket)

/// Cross-platform Cartesia Ink streaming speech-to-text client.
///
/// Shared by macOS and iOS: both feed it linear16 mono PCM captured by their own
/// platform audio layer. Conforms to `StreamingTranscriptionClient`.
public final class CartesiaLiveClient: StreamingTranscriptionClient, @unchecked Sendable {
    private static let host = "api.cartesia.ai"
    private static let path = "/stt/turns/websocket"
    private static let apiVersion = "2026-03-01"
    private static let preferredChunkBytes = 3_200

    private let apiKey: String
    private let model: String
    private let sampleRate: Int
    private let session: URLSession
    private let logger = Logger(subsystem: "com.justspeaktoit", category: "CartesiaLiveClient")
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()

    private var webSocketTask: URLSessionWebSocketTask?
    private var pendingAudio = Data()
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping = false

    public init(
        apiKey: String,
        model: String = "ink-2",
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.sampleRate = sampleRate
        self.session = session
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            isStopping = false
            self.onTranscript = onTranscript
            self.onError = onError
        }
        connectWebSocket()
    }

    public func sendAudio(_ audioData: Data) {
        guard let task = currentWebSocketTask(), task.state == .running else {
            bufferPendingAudio(audioData)
            return
        }
        flushPendingAudio(to: task)
        send(audioData, to: task)
    }

    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            return webSocketTask
        }
        guard let task else { return }
        if task.state == .running {
            task.cancel(with: .normalClosure, reason: nil)
        }
        withStateLock {
            if webSocketTask === task { webSocketTask = nil }
        }
    }

    // MARK: - Connection

    static func webSocketURL(model: String, sampleRate: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "cartesia_version", value: apiVersion)
        ]
        return components.url
    }

    private func connectWebSocket() {
        guard let url = Self.webSocketURL(model: model, sampleRate: sampleRate) else {
            currentOnError()?(StreamingClientError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        // Cartesia authenticates the WebSocket handshake with a Bearer token,
        // matching the macOS provider implementation.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")

        let task = session.webSocketTask(with: request)
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
        logger.info("Cartesia WebSocket connecting (model=\(self.model, privacy: .public))")
        flushPendingAudio(to: task)
        receiveMessages()
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
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
                self.currentOnError()?(self.mapConnectionError(error))
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseResponse(text)
            }
        @unknown default:
            break
        }
    }

    private func parseResponse(_ json: String) {
        // Surface Cartesia `type: "error"` events instead of silently ignoring them.
        if let data = json.data(using: .utf8),
           let errorEvent = try? JSONDecoder().decode(CartesiaErrorEvent.self, from: data),
           errorEvent.type == "error" {
            let message = errorEvent.message ?? errorEvent.title ?? "Cartesia streaming error"
            currentOnError()?(NSError(
                domain: "Cartesia", code: errorEvent.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
            return
        }
        guard let event = Self.transcriptEvent(from: json) else { return }
        currentOnTranscript()?(event.text, event.isFinal)
    }

    static func transcriptEvent(from json: String) -> (text: String, isFinal: Bool)? {
        guard
            let data = json.data(using: .utf8),
            let response = try? JSONDecoder().decode(CartesiaTurnResponse.self, from: data),
            let transcript = response.transcriptText, !transcript.isEmpty
        else {
            return nil
        }
        return (transcript, response.type == "turn.end")
    }

    // MARK: - Sending

    private func send(_ audioData: Data, to task: URLSessionWebSocketTask) {
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.data(audioData)) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self, let error else { return }
            if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
            self.currentOnError()?(self.mapConnectionError(error))
        }
    }

    private func bufferPendingAudio(_ audioData: Data) {
        withStateLock {
            pendingAudio.append(audioData)
            let maxBufferedBytes = Self.preferredChunkBytes * 20
            if pendingAudio.count > maxBufferedBytes {
                pendingAudio = Data(pendingAudio.suffix(maxBufferedBytes))
            }
        }
    }

    private func flushPendingAudio(to task: URLSessionWebSocketTask) {
        let buffered = withStateLock { () -> Data in
            let snapshot = pendingAudio
            pendingAudio.removeAll(keepingCapacity: true)
            return snapshot
        }
        guard !buffered.isEmpty else { return }
        send(buffered, to: task)
    }

    // MARK: - Errors + state

    private func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Cartesia")
        }
        return error
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

private struct CartesiaTurnResponse: Decodable {
    struct Result: Decodable {
        let transcript: String?
    }

    let type: String
    let transcript: String?
    let results: [Result]?

    var transcriptText: String? {
        if let transcript { return transcript }
        return results?.compactMap(\.transcript).first { !$0.isEmpty }
    }
}

private struct CartesiaErrorEvent: Decodable {
    let type: String
    let statusCode: Int?
    let title: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case statusCode = "status_code"
        case title
        case message
    }
}
