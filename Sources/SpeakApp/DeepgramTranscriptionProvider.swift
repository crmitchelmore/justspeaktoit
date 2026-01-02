import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakapp", category: "Deepgram")

// MARK: - DeepgramTranscriptionProvider

struct DeepgramTranscriptionProvider: TranscriptionProvider {
    let metadata = TranscriptionProviderMetadata(
        id: "deepgram",
        displayName: "Deepgram",
        systemImage: "waveform",
        tintColor: "indigo",
        website: "https://deepgram.com"
    )

    private let baseURL = URL(string: "https://api.deepgram.com/v1")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("listen")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
        ]

        if let language {
            let languageCode = extractLanguageCode(from: language)
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: url)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw TranscriptionProviderError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
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
                return .failure(
                    message: "Received a non-HTTP response", debug: debugSnapshot(request: request))
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
                id: "deepgram/nova-2",
                displayName: "Deepgram Nova-2",
                description: "Deepgram's latest speech recognition model with streaming support."
            )
        ]
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }

    private func buildTranscriptionResult(
        response: DeepgramResponse,
        audioURL: URL,
        model: String,
        payload: Data
    ) async throws -> TranscriptionResult {
        let asset = AVURLAsset(url: audioURL)
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds

        let channel = response.results?.channels?.first
        let alternative = channel?.alternatives?.first
        let text = alternative?.transcript ?? ""

        let segments =
            alternative?.words?.map { word in
                TranscriptionSegment(
                    startTime: word.start,
                    endTime: word.end,
                    text: word.word
                )
            } ?? [TranscriptionSegment(startTime: 0, endTime: duration, text: text)]

        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: alternative?.confidence,
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

// MARK: - DeepgramLiveTranscriber

enum DeepgramLiveTranscriberError: LocalizedError {
    case websocketConnectionFailed(String)
    case audioEngineSetupFailed(String)
    case bothComponentsFailed(websocket: String, audio: String)

    var errorDescription: String? {
        switch self {
        case .websocketConnectionFailed(let message):
            return "WebSocket connection failed: \(message)"
        case .audioEngineSetupFailed(let message):
            return "Audio engine setup failed: \(message)"
        case .bothComponentsFailed(let websocket, let audio):
            return "Both components failed - WebSocket: \(websocket), Audio: \(audio)"
        }
    }
}

@MainActor
final class DeepgramLiveTranscriber: NSObject, LiveTranscriptionController {
    weak var delegate: LiveTranscriptionSessionDelegate?
    private(set) var isRunning: Bool = false

    private let audioDeviceManager: AudioInputDeviceManager
    private let secureStorage: SecureAppStorage
    private let audioEngine = AVAudioEngine()
    private var webSocketTask: URLSessionWebSocketTask?
    private var currentLocaleIdentifier: String?
    private var currentModel: String?
    private var activeInputSession: AudioInputDeviceManager.SessionContext?
    private var accumulatedText: String = ""

    init(
        audioDeviceManager: AudioInputDeviceManager,
        secureStorage: SecureAppStorage
    ) {
        self.audioDeviceManager = audioDeviceManager
        self.secureStorage = secureStorage
    }

    func configure(language: String?, model: String) {
        currentLocaleIdentifier = language
        currentModel = model
    }

    func start() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("Starting DeepgramLiveTranscriber - beginning parallel setup")

        let apiKey = try await getAPIKey()
        let sessionContext = await audioDeviceManager.beginUsingPreferredInput()

        // Run WebSocket connection AND audio engine setup in parallel using async let
        async let webSocketResult = connectWebSocket(apiKey: apiKey)
        async let audioResult = setupAudioEngine()

        let wsStartTime = CFAbsoluteTimeGetCurrent()
        let audioStartTime = CFAbsoluteTimeGetCurrent()

        do {
            // Await both results - they run concurrently
            let (webSocket, audioFormat) = try await (webSocketResult, audioResult)

            let wsElapsed = CFAbsoluteTimeGetCurrent() - wsStartTime
            let audioElapsed = CFAbsoluteTimeGetCurrent() - audioStartTime
            logger.info(
                "Parallel setup complete - WebSocket: \(wsElapsed, privacy: .public)s, Audio: \(audioElapsed, privacy: .public)s"
            )

            // Both are ready - store references and start sending audio
            self.webSocketTask = webSocket
            self.activeInputSession = sessionContext

            // Install audio tap and start streaming
            try startAudioStreaming(format: audioFormat)

            // Start receiving WebSocket messages
            startReceivingMessages()

            let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
            logger.info("DeepgramLiveTranscriber started successfully in \(totalElapsed, privacy: .public)s")

            isRunning = true
            accumulatedText = ""

        } catch {
            // Handle failures - clean up any partially initialized components
            logger.error("Parallel setup failed: \(error.localizedDescription, privacy: .public)")

            await audioDeviceManager.endUsingPreferredInput(session: sessionContext)
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil

            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }

            throw error
        }
    }

    func stop() async {
        guard isRunning else { return }
        logger.info("Stopping DeepgramLiveTranscriber")

        // Stop audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        // Close WebSocket gracefully
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        isRunning = false

        // Notify delegate with final result
        let result = TranscriptionResult(
            text: accumulatedText,
            segments: [],
            confidence: nil,
            duration: 0,
            modelIdentifier: currentModel ?? "deepgram/nova-2",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
        delegate?.liveTranscriber(self, didFinishWith: result)

        await endActiveInputSession()
    }

    // MARK: - Private: Parallel Setup Components

    private func connectWebSocket(apiKey: String) async throws -> URLSessionWebSocketTask {
        let connectStartTime = CFAbsoluteTimeGetCurrent()
        logger.info("Starting WebSocket connection...")

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
        ]

        if let language = currentLocaleIdentifier {
            let code = extractLanguageCode(from: language)
            queryItems.append(URLQueryItem(name: "language", value: code))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let webSocket = session.webSocketTask(with: request)
        webSocket.resume()

        // Wait for connection to be established by sending a ping
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocket.sendPing { error in
                if let error {
                    continuation.resume(throwing: DeepgramLiveTranscriberError.websocketConnectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - connectStartTime
        logger.info("WebSocket connected in \(elapsed, privacy: .public)s")

        return webSocket
    }

    private func setupAudioEngine() async throws -> AVAudioFormat {
        let setupStartTime = CFAbsoluteTimeGetCurrent()
        logger.info("Starting audio engine setup...")

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Create format for Deepgram: 16kHz, mono, 16-bit PCM
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: true
            )
        else {
            throw DeepgramLiveTranscriberError.audioEngineSetupFailed(
                "Failed to create target audio format")
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            throw DeepgramLiveTranscriberError.audioEngineSetupFailed(error.localizedDescription)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - setupStartTime
        logger.info("Audio engine ready in \(elapsed, privacy: .public)s (native format: \(nativeFormat.sampleRate, privacy: .public)Hz)")

        return targetFormat
    }

    private func startAudioStreaming(format: AVAudioFormat) throws {
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Install tap to capture and convert audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) {
            [weak self] buffer, _ in
            guard let self, let webSocket = self.webSocketTask else { return }

            // Convert to 16kHz mono PCM
            guard let convertedData = self.convertToPCM16(buffer: buffer, targetFormat: format)
            else { return }

            let message = URLSessionWebSocketTask.Message.data(convertedData)
            webSocket.send(message) { error in
                if let error {
                    Task { @MainActor in
                        self.delegate?.liveTranscriber(self, didFail: error)
                    }
                }
            }
        }
    }

    private func startReceivingMessages() {
        guard let webSocket = webSocketTask else { return }

        webSocket.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                Task { @MainActor in
                    self.handleWebSocketMessage(message)
                }
                // Continue receiving
                self.startReceivingMessages()

            case .failure(let error):
                Task { @MainActor in
                    if self.isRunning {
                        self.delegate?.liveTranscriber(self, didFail: error)
                    }
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseTranscriptMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseTranscriptMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseTranscriptMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
            let response = try? JSONDecoder().decode(DeepgramStreamingResponse.self, from: data)
        else { return }

        guard let channel = response.channel,
            let alternative = channel.alternatives?.first,
            !alternative.transcript.isEmpty
        else { return }

        if response.is_final == true {
            // Final transcript for this utterance
            if !accumulatedText.isEmpty {
                accumulatedText += " "
            }
            accumulatedText += alternative.transcript
        }

        // Report partial or final updates
        let displayText =
            response.is_final == true ? accumulatedText : accumulatedText + " " + alternative.transcript
        delegate?.liveTranscriber(self, didUpdatePartial: displayText.trimmingCharacters(in: .whitespaces))
    }

    private func convertToPCM16(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> Data? {
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCapacity
            )
        else { return nil }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if error != nil { return nil }

        guard let int16Data = outputBuffer.int16ChannelData else { return nil }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: int16Data[0], count: byteCount)
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }

    private func getAPIKey() async throws -> String {
        guard
            let key = try? await secureStorage.secret(
                identifier: "deepgram.apiKey")
        else {
            throw TranscriptionProviderError.apiKeyMissing
        }
        return key
    }

    private func endActiveInputSession() async {
        guard let session = activeInputSession else { return }
        activeInputSession = nil
        await audioDeviceManager.endUsingPreferredInput(session: session)
    }
}

// MARK: - Response Models

private struct DeepgramResponse: Decodable {
    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                struct Word: Decodable {
                    let word: String
                    let start: TimeInterval
                    let end: TimeInterval
                    let confidence: Double
                }

                let transcript: String
                let confidence: Double?
                let words: [Word]?
            }

            let alternatives: [Alternative]?
        }

        let channels: [Channel]?
    }

    let results: Results?
}

private struct DeepgramStreamingResponse: Decodable {
    struct Channel: Decodable {
        struct Alternative: Decodable {
            let transcript: String
            let confidence: Double?
        }

        let alternatives: [Alternative]?
    }

    let channel: Channel?
    let is_final: Bool?
    let speech_final: Bool?
}
