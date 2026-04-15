import AVFoundation
import Foundation
import os.log
import SpeakCore

// MARK: - Errors

enum ElevenLabsLiveError: LocalizedError {
    case missingAPIKey
    case invalidURLComponents
    case connectionFailed
    case invalidAPIKeyOrMissingScribeAccess

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "ElevenLabs API key is missing. Please add it in Settings → ElevenLabs."
        case .invalidURLComponents:
            return "Failed to construct ElevenLabs WebSocket URL."
        case .connectionFailed:
            return "Failed to establish WebSocket connection to ElevenLabs."
        case .invalidAPIKeyOrMissingScribeAccess:
            return "ElevenLabs API key is invalid or does not have speech-to-text (Scribe) access. "
                + "Check your key in Settings → ElevenLabs."
        }
    }
}

// MARK: - WebSocket response types

private struct ElevenLabsStreamEnvelope: Decodable {
    let type: String
}

private struct ElevenLabsTranscriptEvent: Decodable {
    let text: String
    let type: String   // "partial" or "final"
}

private struct ElevenLabsTranscriptMessage: Decodable {
    let type: String
    let transcriptEvent: ElevenLabsTranscriptEvent?

    private enum CodingKeys: String, CodingKey {
        case type
        case transcriptEvent = "transcript_event"
    }
}

// MARK: - Live Transcriber (WebSocket client)

/// Streams raw PCM audio to ElevenLabs Scribe v2 real-time API and delivers partial/final
/// transcript callbacks.  Auth uses `xi-api-key` header — no URL-level key exposure.
final class ElevenLabsLiveTranscriber: @unchecked Sendable {
    // Connection URL is constructed in connectWebSocket(); never logged.
    private static let websocketHost = "api.elevenlabs.io"
    private static let websocketPath = "/v1/speech-to-text/realtime"

    /// Minimum PCM chunk size: 100 ms at 16 kHz PCM16 mono.
    static let minimumChunkBytes = 3_200
    /// Preferred PCM chunk size: 100 ms at 16 kHz PCM16 mono.
    static let preferredChunkBytes = 3_200

    private let apiKey: String
    private let modelID: String
    private let sampleRate: Int
    private let session: URLSession
    private let bufferPool: AudioBufferPool
    private let logger = Logger(subsystem: "com.speak.app", category: "ElevenLabsLiveTranscriber")
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false

    init(
        apiKey: String,
        modelID: String = "scribe_v2",
        sampleRate: Int = 16000,
        session: URLSession = .shared,
        bufferPool: AudioBufferPool = AudioBufferPool(poolSize: 10, bufferSize: 4096)
    ) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.sampleRate = sampleRate
        self.session = session
        self.bufferPool = bufferPool
    }

    func start(
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

    func sendAudio(_ audioData: Data) {
        guard let task = currentWebSocketTask(), task.state == .running else { return }

        var buffer = bufferPool.checkout()
        buffer.append(audioData)

        let dataToSend = buffer
        let message = URLSessionWebSocketTask.Message.data(dataToSend)
        let sendGroup = pendingSendGroup
        sendGroup.enter()

        task.send(message) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self else { return }
            var returnBuffer = buffer
            self.bufferPool.returnBuffer(&returnBuffer)

            if let error {
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.currentOnError()?(error)
            }
        }
    }

    func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            if webSocketTask?.state != .running {
                webSocketTask = nil
            }
            return webSocketTask
        }
        bufferPool.logMetrics()

        guard let task, task.state == .running else { return }
        task.cancel(with: .normalClosure, reason: nil)
        withStateLock {
            if webSocketTask === task {
                webSocketTask = nil
            }
        }
        logger.info("ElevenLabs WebSocket connection closed")
    }

    func waitForPendingSends(timeout: TimeInterval = 1.5) async {
        let sendGroup = pendingSendGroup
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = sendGroup.wait(timeout: .now() + timeout)
                continuation.resume()
            }
        }
    }

    // MARK: - Private

    private func connectWebSocket() {
        var urlComponents = URLComponents()
        urlComponents.scheme = "wss"
        urlComponents.host = Self.websocketHost
        urlComponents.path = Self.websocketPath
        urlComponents.queryItems = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "inactivity_timeout", value: "10")
        ]

        guard let url = urlComponents.url else {
            currentOnError()?(ElevenLabsLiveError.invalidURLComponents)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let task = session.webSocketTask(with: request)
        let shouldReceive = withStateLock { () -> Bool in
            guard !isStopping else { return false }
            webSocketTask = task
            task.resume()
            return true
        }
        guard shouldReceive else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }

        logger.info("ElevenLabs WebSocket connecting")
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
                if self.isStoppingState() { return }
                if self.shouldIgnoreSocketError(error) { return }
                let mapped = self.mapConnectionError(error)
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                self.currentOnError()?(mapped)
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
        logger.debug("ElevenLabs response (length: \(json.count))")
        guard let data = json.data(using: .utf8) else { return }

        do {
            let envelope = try JSONDecoder().decode(ElevenLabsStreamEnvelope.self, from: data)
            switch envelope.type {
            case "transcript":
                let msg = try JSONDecoder().decode(ElevenLabsTranscriptMessage.self, from: data)
                guard let event = msg.transcriptEvent, !event.text.isEmpty else { return }
                let isFinal = event.type == "final"
                currentOnTranscript()?(event.text, isFinal)
            case "close_connection":
                logger.info("ElevenLabs server sent close_connection")
            default:
                logger.debug("Unhandled ElevenLabs message type: \(envelope.type)")
            }
        } catch {
            logger.debug("Failed to parse ElevenLabs response: \(error.localizedDescription)")
        }
    }

    private func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.code == 401 || nsError.code == 403 {
            return ElevenLabsLiveError.invalidAPIKeyOrMissingScribeAccess
        }
        let description = nsError.localizedDescription.lowercased()
        if description.contains("401")
            || description.contains("unauthorized")
            || description.contains("403")
            || description.contains("forbidden") {
            return ElevenLabsLiveError.invalidAPIKeyOrMissingScribeAccess
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
}

private extension ElevenLabsLiveTranscriber {
    func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    func currentWebSocketTask() -> URLSessionWebSocketTask? {
        withStateLock { webSocketTask }
    }

    func isStoppingState() -> Bool {
        withStateLock { isStopping }
    }

    func currentOnTranscript() -> ((String, Bool) -> Void)? {
        withStateLock { onTranscript }
    }

    func currentOnError() -> ((Error) -> Void)? {
        withStateLock { onError }
    }
}
