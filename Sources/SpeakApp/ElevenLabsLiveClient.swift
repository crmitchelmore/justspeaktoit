import Foundation
import os.log

// MARK: - ElevenLabs Live Client (WebSocket)

/// macOS WebSocket client for ElevenLabs Scribe v2 real-time transcription.
/// Auth: `xi-api-key` header on the WebSocket handshake (never query parameter).
final class ElevenLabsLiveClient: @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private let logger = Logger(subsystem: "com.speak.app", category: "ElevenLabsLiveClient")

    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false

    init(
        apiKey: String,
        model: String = "scribe_v2",
        language: String? = nil,
        sampleRate: Int = 16000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.session = session
    }

    /// Starts a live transcription session.
    /// - Parameters:
    ///   - onTranscript: Called with transcript text and whether it's final.
    ///   - onError: Called when an error occurs.
    func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        isStopping = false
        self.onTranscript = onTranscript
        self.onError = onError

        guard let url = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text") else {
            onError(ElevenLabsLiveError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        logger.info("ElevenLabs WebSocket connection started")
        receiveMessages()
        sendInitMessage()
    }

    /// Sends raw PCM16 audio data to the transcription service.
    func sendAudio(_ audioData: Data) {
        guard let webSocketTask, webSocketTask.state == .running else { return }

        let message = URLSessionWebSocketTask.Message.data(audioData)
        webSocketTask.send(message) { [weak self] error in
            guard let self else { return }
            if let error {
                if self.isStopping || self.shouldIgnoreSocketError(error) { return }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.onError?(error)
            }
        }
    }

    /// Signals end of audio stream, flushing any pending transcription.
    func sendEndOfStream() {
        guard let webSocketTask, webSocketTask.state == .running else { return }

        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "end_of_stream"]),
              let json = String(data: data, encoding: .utf8) else { return }

        webSocketTask.send(.string(json)) { [weak self] error in
            if let error, !(self?.isStopping ?? true) {
                self?.logger.error("Failed to send end_of_stream: \(error.localizedDescription)")
            }
        }
        logger.info("ElevenLabs end_of_stream sent")
    }

    /// Stops the transcription session.
    func stop() {
        isStopping = true
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        logger.info("ElevenLabs WebSocket connection closed")
    }

    var isConnected: Bool {
        webSocketTask?.state == .running
    }

    // MARK: - Private

    private func sendInitMessage() {
        var payload: [String: Any] = [
            "type": "websocket_config",
            "model_id": model
        ]
        if let language {
            payload["language_code"] = extractLanguageCode(from: language)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(json)) { [weak self] error in
            if let error {
                self?.logger.error("Failed to send init message: \(error.localizedDescription)")
            }
        }
        logger.info("ElevenLabs init message sent (model: \(self.model))")
    }

    private func shouldIgnoreSocketError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true }
        if nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
            return true
        }
        return false
    }

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessages()
            case .failure(let error):
                if self.isStopping || self.shouldIgnoreSocketError(error) { return }
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                self.onError?(error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseTranscriptResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseTranscriptResponse(text)
            }
        @unknown default:
            break
        }
    }

    private func parseTranscriptResponse(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        do {
            let response = try JSONDecoder().decode(ElevenLabsTranscriptEvent.self, from: data)
            guard response.type == "transcript", !response.transcript.isEmpty else { return }
            onTranscript?(response.transcript, response.is_final)
        } catch {
            logger.debug("Failed to parse ElevenLabs response: \(error.localizedDescription)")
        }
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }
}

// MARK: - Response Models

private struct ElevenLabsTranscriptEvent: Decodable {
    let type: String
    let transcript: String
    let is_final: Bool

    // Custom decode to handle missing fields gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        transcript = (try? container.decode(String.self, forKey: .transcript)) ?? ""
        is_final = (try? container.decode(Bool.self, forKey: .is_final)) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case type, transcript, is_final
    }
}

// MARK: - Error Types

enum ElevenLabsLiveError: LocalizedError {
    case invalidURL
    case connectionFailed
    case missingAPIKey
    case insufficientCapabilities

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct ElevenLabs WebSocket URL"
        case .connectionFailed:
            return "Failed to establish WebSocket connection to ElevenLabs"
        case .missingAPIKey:
            return "ElevenLabs API key is missing. Please configure it in Settings."
        case .insufficientCapabilities:
            return "ElevenLabs API key does not have Speech-to-Text access. Please check your ElevenLabs subscription."
        }
    }
}
