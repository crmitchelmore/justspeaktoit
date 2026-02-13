import SpeakCore
import AVFoundation
import Foundation
import os.log

// MARK: - Deepgram Live Transcriber

/// Handles real-time audio streaming to Deepgram's WebSocket API.
final class DeepgramLiveTranscriber: @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private var unfairLock = os_unfair_lock()
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private let bufferPool: AudioBufferPool
    private let logger = Logger(subsystem: "com.speak.app", category: "DeepgramLiveTranscriber")

    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false

    init(
        apiKey: String,
        model: String = "nova-3",
        language: String? = nil,
        sampleRate: Int = 16000,
        session: URLSession = .shared,
        bufferPool: AudioBufferPool = AudioBufferPool(poolSize: 10, bufferSize: 4096)
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.session = session
        self.bufferPool = bufferPool
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

        var urlComponents = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "vad_events", value: "true")
        ]

        if let language {
            let languageCode = extractLanguageCode(from: language)
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            onError(DeepgramError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        print("[DeepgramLiveTranscriber] WebSocket URL: \(url.absoluteString)")
        logger.info("Deepgram WebSocket connection started")
        receiveMessages()
    }

    /// Sends audio data to the transcription service using a pooled buffer.
    /// - Parameter audioData: Raw audio data in the expected format.
    func sendAudio(_ audioData: Data) {
        guard let webSocketTask, webSocketTask.state == .running else {
            return
        }

        // Use pooled buffer for the send operation
        var buffer = bufferPool.checkout()
        buffer.append(audioData)

        let dataToSend = buffer
        let message = URLSessionWebSocketTask.Message.data(dataToSend)

        webSocketTask.send(message) { [weak self] error in
            guard let self else { return }

            // Return buffer to pool after send completes
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

    /// Sends audio from an AVAudioPCMBuffer using a pooled buffer.
    /// - Parameter pcmBuffer: Audio buffer from capture.
    func sendAudio(from pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }

        let frameLength = Int(pcmBuffer.frameLength)
        var buffer = bufferPool.checkout()

        // Convert Float32 samples to Int16 (linear16)
        buffer.reserveCapacity(frameLength * 2)
        for i in 0..<frameLength {
            let sample = channelData[0][i]
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

    /// Stops the transcription session and logs buffer pool metrics.
    func stop() {
        isStopping = true
        bufferPool.logMetrics()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        logger.info("Deepgram WebSocket connection closed")
    }

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
        os_unfair_lock_lock(&unfairLock)
        let task = webSocketTask
        let stopping = isStopping
        let errorHandler = onError
        os_unfair_lock_unlock(&unfairLock)
        
        task?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessages()

            case .failure(let error):
                if stopping || self.shouldIgnoreSocketError(error) {
                    return
                }
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                errorHandler?(error)
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
        logger.debug("Received Deepgram response (length: \(json.count))")
        guard let data = json.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(DeepgramStreamResponse.self, from: data)

            guard let channel = response.channel,
                  let alternative = channel.alternatives.first,
                  !alternative.transcript.isEmpty else {
                return
            }

            let isFinal = response.is_final ?? false
            onTranscript?(alternative.transcript, isFinal)

        } catch {
            logger.debug("Failed to parse transcript response: \(error.localizedDescription)")
        }
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }
}

// MARK: - Deepgram Transcription Provider

struct DeepgramTranscriptionProvider: TranscriptionProvider {
    let metadata = TranscriptionProviderMetadata(
        id: "deepgram",
        displayName: "Deepgram",
        systemImage: "waveform.circle",
        tintColor: "indigo",
        website: "https://deepgram.com"
    )

    private let baseURL = URL(string: "https://api.deepgram.com/v1")!
    private let session: URLSession
    private let bufferPool: AudioBufferPool

    init(session: URLSession = .shared, bufferPool: AudioBufferPool? = nil) {
        self.session = session
        self.bufferPool = bufferPool ?? AudioBufferPool(poolSize: 10, bufferSize: 8192)
    }

    func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("listen")

        guard var urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw TranscriptionProviderError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(name: "model", value: extractModelName(from: model)),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true")
        ]

        if let language {
            let languageCode = extractLanguageCode(from: language)
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }

        urlComponents.queryItems = queryItems

        guard let requestURL = urlComponents.url else {
            throw TranscriptionProviderError.invalidResponse
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: url)
        request.httpBody = audioData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw TranscriptionProviderError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(DeepgramBatchResponse.self, from: data)
        return try await buildTranscriptionResult(
            response: decoded,
            audioURL: url,
            model: model,
            payload: data
        )
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "API key is empty")
        }

        let url = baseURL.appendingPathComponent("projects")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Received a non-HTTP response", debug: debugSnapshot(request: request))
            }

            let debug = debugSnapshot(request: request, response: http, data: data)

            if (200..<300).contains(http.statusCode) {
                return .success(message: "Deepgram API key validated", debug: debug)
            }

            let message = "HTTP \(http.statusCode) while validating key"
            return .failure(message: message, debug: debug)
        } catch {
            return .failure(
                message: "Validation failed: \(error.localizedDescription)",
                debug: debugSnapshot(request: request, error: error)
            )
        }
    }

    func requiresAPIKey(for model: String) -> Bool {
        true
    }

    func supportedModels() -> [ModelCatalog.Option] {
        [
            ModelCatalog.Option(
                id: "deepgram/nova-3",
                displayName: "Nova-3",
                description: "Deepgram's highest-performing speech-to-text model."
            ),
            ModelCatalog.Option(
                id: "deepgram/nova",
                displayName: "Nova",
                description: "Deepgram's previous generation model. Fast and reliable."
            ),
            ModelCatalog.Option(
                id: "deepgram/enhanced",
                displayName: "Enhanced",
                description: "Optimized for specific use cases like phone calls and meetings."
            ),
            ModelCatalog.Option(
                id: "deepgram/base",
                displayName: "Base",
                description: "Deepgram's base model. Good balance of speed and accuracy."
            )
        ]
    }

    /// Creates a live transcriber for streaming audio.
    func createLiveTranscriber(
        apiKey: String,
        model: String = "nova-3",
        language: String? = nil,
        sampleRate: Int = 16000
    ) -> DeepgramLiveTranscriber {
        DeepgramLiveTranscriber(
            apiKey: apiKey,
            model: extractModelName(from: model),
            language: language,
            sampleRate: sampleRate,
            session: session,
            bufferPool: bufferPool
        )
    }

    // MARK: - Private Methods

    private func extractModelName(from model: String) -> String {
        // Extract the model name after the "/" and remove any "-streaming" suffix
        var name = model.split(separator: "/").last.map(String.init) ?? model
        if name.hasSuffix("-streaming") {
            name = String(name.dropLast("-streaming".count))
        }
        return name
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }

    private func buildTranscriptionResult(
        response: DeepgramBatchResponse,
        audioURL: URL,
        model: String,
        payload: Data
    ) async throws -> TranscriptionResult {
        let asset = AVURLAsset(url: audioURL)
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds

        guard let channel = response.results?.channels.first,
              let alternative = channel.alternatives.first else {
            return TranscriptionResult(
                text: "",
                segments: [],
                confidence: nil,
                duration: duration,
                modelIdentifier: model,
                cost: nil,
                rawPayload: String(data: payload, encoding: .utf8),
                debugInfo: nil
            )
        }

        let text = alternative.transcript
        let segments: [TranscriptionSegment]

        if let words = alternative.words, !words.isEmpty {
            segments = words.map { word in
                TranscriptionSegment(
                    startTime: word.start,
                    endTime: word.end,
                    text: word.word
                )
            }
        } else {
            segments = [TranscriptionSegment(startTime: 0, endTime: duration, text: text)]
        }

        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: alternative.confidence,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: String(data: payload, encoding: .utf8),
            debugInfo: nil
        )
    }

    private func debugSnapshot(
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        data: Data? = nil,
        error: Error? = nil
    ) -> APIKeyValidationDebugSnapshot {
        APIKeyValidationDebugSnapshot(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestBody: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            statusCode: response?.statusCode,
            responseHeaders: response.map { headers in
                headers.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
                    guard let key = entry.key as? String else { return }
                    partialResult[key] = String(describing: entry.value)
                }
            } ?? [:],
            responseBody: data.flatMap { String(data: $0, encoding: .utf8) },
            errorDescription: error?.localizedDescription
        )
    }
}

// MARK: - Response Models

private struct DeepgramStreamResponse: Decodable {
    struct Channel: Decodable {
        struct Alternative: Decodable {
            let transcript: String
            let confidence: Double?
        }

        let alternatives: [Alternative]
    }

    let channel: Channel?
    let is_final: Bool?
}

private struct DeepgramBatchResponse: Decodable {
    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                struct Word: Decodable {
                    let word: String
                    let start: TimeInterval
                    let end: TimeInterval
                    let confidence: Double?
                }

                let transcript: String
                let confidence: Double?
                let words: [Word]?
            }

            let alternatives: [Alternative]
        }

        let channels: [Channel]
    }

    let results: Results?
}

// MARK: - Error Types

enum DeepgramError: LocalizedError {
    case invalidURL
    case connectionFailed
    case sendFailed
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct Deepgram WebSocket URL"
        case .connectionFailed:
            return "Failed to establish WebSocket connection to Deepgram"
        case .sendFailed:
            return "Failed to send audio data to Deepgram"
        case .missingAPIKey:
            return "Deepgram API key is missing. Please configure it in Settings."
        }
    }
}
