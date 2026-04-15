import Foundation
import os.log

// MARK: - ElevenLabs Live Client (Cross-platform WebSocket)

/// Cross-platform ElevenLabs WebSocket client for live speech-to-text.
/// Works on both macOS and iOS.
public final class ElevenLabsLiveClient: @unchecked Sendable {
    private let apiKey: String
    private let modelID: String
    private let language: String?
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private let bufferPool: AudioBufferPool
    private let logger = Logger(subsystem: "com.speak.app", category: "ElevenLabsLiveClient")

    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false

    public init(
        apiKey: String,
        modelID: String = "scribe_v1",
        language: String? = nil,
        session: URLSession = .shared,
        bufferPool: AudioBufferPool = AudioBufferPool(poolSize: 10, bufferSize: 4096)
    ) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.language = language
        self.session = session
        self.bufferPool = bufferPool
    }

    /// Starts a live transcription session.
    /// - Parameters:
    ///   - onTranscript: Called with transcript text and whether it's final.
    ///   - onError: Called when an error occurs.
    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        isStopping = false
        self.onTranscript = onTranscript
        self.onError = onError

        var urlComponents = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/stream")!
        var queryItems = [URLQueryItem(name: "model_id", value: modelID)]

        if let language {
            let code = extractLanguageCode(from: language)
            queryItems.append(URLQueryItem(name: "language_code", value: code))
        }

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            onError(ElevenLabsLiveError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        logger.info("ElevenLabs WebSocket connection started")
        receiveMessages()
    }

    /// Sends raw PCM Int16 audio data to the transcription service.
    public func sendAudio(_ audioData: Data) {
        guard let webSocketTask, webSocketTask.state == .running else {
            return
        }

        var buffer = bufferPool.checkout()
        buffer.append(audioData)

        let dataToSend = buffer
        let message = URLSessionWebSocketTask.Message.data(dataToSend)

        webSocketTask.send(message) { [weak self] error in
            guard let self else { return }

            var returnBuffer = buffer
            self.bufferPool.returnBuffer(&returnBuffer)

            if let error {
                if self.isStopping || self.shouldIgnoreSocketError(error) {
                    return
                }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.onError?(error)
            }
        }
    }

    /// Sends Float32 audio samples converted to Int16 linear PCM.
    public func sendAudioSamples(_ samples: UnsafePointer<Float>, frameCount: Int) {
        var buffer = bufferPool.checkout()
        buffer.reserveCapacity(frameCount * 2)

        for sampleIndex in 0..<frameCount {
            let sample = samples[sampleIndex]
            let clampedSample = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clampedSample * Float(Int16.max))
            withUnsafeBytes(of: int16Sample.littleEndian) { bytes in
                buffer.append(contentsOf: bytes)
            }
        }

        guard let webSocketTask, webSocketTask.state == .running else {
            bufferPool.returnBuffer(&buffer)
            return
        }

        let dataToSend = buffer
        let message = URLSessionWebSocketTask.Message.data(dataToSend)

        webSocketTask.send(message) { [weak self] error in
            guard let self else { return }

            var returnBuffer = buffer
            self.bufferPool.returnBuffer(&returnBuffer)

            if let error {
                if self.isStopping || self.shouldIgnoreSocketError(error) {
                    return
                }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.onError?(error)
            }
        }
    }

    /// Stops the transcription session.
    public func stop() {
        isStopping = true
        bufferPool.logMetrics()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        logger.info("ElevenLabs WebSocket connection closed")
    }

    /// Check if the client is currently connected.
    public var isConnected: Bool {
        webSocketTask?.state == .running
    }

    // MARK: - Private

    private func shouldIgnoreSocketError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { // ENOTCONN
            return true
        }
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
                if self.isStopping || self.shouldIgnoreSocketError(error) {
                    return
                }
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
            let response = try JSONDecoder().decode(ElevenLabsStreamResponse.self, from: data)

            guard let transcript = response.transcript, !transcript.isEmpty else {
                return
            }

            let isFinal = response.speechEventType == "FINAL_TRANSCRIPT"
            onTranscript?(transcript, isFinal)

        } catch {
            logger.debug("Failed to parse transcript response: \(error.localizedDescription)")
        }
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }
}

// MARK: - Response Models

private struct ElevenLabsStreamResponse: Decodable {
    /// "PARTIAL_TRANSCRIPT" or "FINAL_TRANSCRIPT"
    let speechEventType: String?
    let transcript: String?

    enum CodingKeys: String, CodingKey {
        case speechEventType = "speech_event_type"
        case transcript
    }
}

// MARK: - Error Types

public enum ElevenLabsLiveError: LocalizedError {
    case invalidURL
    case connectionFailed
    case sendFailed
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct ElevenLabs WebSocket URL"
        case .connectionFailed:
            return "Failed to establish WebSocket connection to ElevenLabs"
        case .sendFailed:
            return "Failed to send audio data to ElevenLabs"
        case .missingAPIKey:
            return "ElevenLabs API key is missing. Please configure it in Settings."
        }
    }
}

// MARK: - API Key Validation

public struct ElevenLabsSTTAPIKeyValidator {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Validates an ElevenLabs API key by calling the user endpoint.
    public func validate(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "API key is empty")
        }

        let url = URL(string: "https://api.elevenlabs.io/v1/user")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(trimmed, forHTTPHeaderField: "xi-api-key")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Received a non-HTTP response")
            }

            if (200..<300).contains(http.statusCode) {
                return .success(message: "ElevenLabs API key validated")
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            return .failure(message: "HTTP \(http.statusCode): \(body)")
        } catch {
            return .failure(message: "Validation failed: \(error.localizedDescription)")
        }
    }
}
