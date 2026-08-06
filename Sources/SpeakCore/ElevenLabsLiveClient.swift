// swiftlint:disable file_length
import Foundation
import os.log

// MARK: - ElevenLabs Live Client (Cross-platform WebSocket)

/// Cross-platform ElevenLabs WebSocket client for live speech-to-text.
/// Works on both macOS and iOS.
public final class ElevenLabsLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    private let apiKey: String
    private let modelID: String
    private let language: String?
    private let session: URLSession
    private let bufferPool: AudioBufferPool
    private let logger = SpeakLogger.logger(category: "ElevenLabsLiveClient")
    private let stateLock = NSLock()

    // Guarded by `stateLock`: mutated by the caller while URLSession callbacks read them.
    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false
    /// Guarded by `stateLock`: the session's full transcript, folded from the
    /// finals ElevenLabs streams. `finishAndWait()` returns this, per the
    /// `FinalizingStreamingTranscriptionClient` contract.
    private var accumulated = TranscriptAccumulator()

    /// Bounded post-stop drain state: while `finishAndWait()` is pending, the
    /// trailing final is folded in and the full transcript is handed to the
    /// waiter instead of `onTranscript`, so the caller never sees the same
    /// words twice.
    private let finishLock = NSLock()
    private var finishContinuation: CheckedContinuation<String?, Never>?
    private static let finishDrainBudget: TimeInterval = 1.0

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
        withStateLock {
            isStopping = false
            accumulated.reset()
            self.onTranscript = onTranscript
            self.onError = onError
        }

        var urlComponents = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/stream")!
        var queryItems = [URLQueryItem(name: "model_id", value: modelID)]

        if let language {
            queryItems.append(URLQueryItem(name: "language_code", value: language.localeLanguageCode))
        }

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            onError(ElevenLabsLiveError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let task = session.webSocketTask(with: request)
        // `stop()` can land while the task is being created; publishing
        // unconditionally would resurrect a session the caller already ended.
        let published = withStateLock { () -> Bool in
            guard !isStopping else { return false }
            webSocketTask = task
            return true
        }
        guard published else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        task.resume()

        logger.info("ElevenLabs WebSocket connection started")
        receiveMessages()
    }

    /// Sends raw PCM Int16 audio data to the transcription service.
    public func sendAudio(_ audioData: Data) {
        guard let task = currentWebSocketTask(), task.state == .running else {
            return
        }

        var buffer = bufferPool.checkout()
        buffer.append(audioData)

        let dataToSend = buffer
        let message = URLSessionWebSocketTask.Message.data(dataToSend)

        task.send(message) { [weak self] error in
            guard let self else { return }

            var returnBuffer = buffer
            self.bufferPool.returnBuffer(&returnBuffer)

            if let error {
                if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) {
                    return
                }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.currentOnError()?(error)
            }
        }
    }

    /// Sends Float32 audio samples converted to Int16 linear PCM.
    public func sendAudioSamples(_ samples: UnsafePointer<Float>, frameCount: Int) {
        var buffer = bufferPool.checkout()
        buffer.reserveCapacity(frameCount * MemoryLayout<Int16>.size)

        // Single-pass Float32 → Int16 conversion into a preallocated array,
        // appended in one bulk copy instead of 2 bytes per sample.
        var int16Samples = [Int16](repeating: 0, count: frameCount)
        for sampleIndex in 0..<frameCount {
            let sample = samples[sampleIndex]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Samples[sampleIndex] = Int16(clampedSample * Float(Int16.max)).littleEndian
        }
        int16Samples.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                buffer.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: rawBuffer.count)
            }
        }

        guard let task = currentWebSocketTask(), task.state == .running else {
            bufferPool.returnBuffer(&buffer)
            return
        }

        let dataToSend = buffer
        let message = URLSessionWebSocketTask.Message.data(dataToSend)

        task.send(message) { [weak self] error in
            guard let self else { return }

            var returnBuffer = buffer
            self.bufferPool.returnBuffer(&returnBuffer)

            if let error {
                if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) {
                    return
                }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.currentOnError()?(error)
            }
        }
    }

    /// The streaming endpoint has no documented end-of-stream frame, so
    /// `finishAndWait()` cannot flush audio ElevenLabs hasn't transcribed yet —
    /// callers with nothing outstanding should close immediately.
    public var finishFlushesBufferedAudio: Bool { false }

    /// Graceful stop: waits (bounded) for the trailing final transcript before
    /// closing the socket, so words spoken just before stop aren't lost. The
    /// streaming endpoint has no documented end-of-stream frame, so this is a
    /// bounded wait only.
    ///
    /// Returns the session's **full** transcript (every final ElevenLabs sent,
    /// including any that arrived during the wait), or `nil` when nothing was
    /// transcribed. A trailing final consumed here is not also delivered
    /// through `onTranscript`.
    public func finishAndWait() async -> String? {
        guard currentWebSocketTask()?.state == .running else {
            stop()
            return fullTranscript()
        }

        let transcript: String? = await withCheckedContinuation { continuation in
            finishLock.lock()
            finishContinuation = continuation
            finishLock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + Self.finishDrainBudget) { [weak self] in
                self?.resolveFinish()
            }
        }
        stop()
        return transcript
    }

    /// Stops the transcription session.
    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            isStopping = true
            let task = webSocketTask
            webSocketTask = nil
            return task
        }
        bufferPool.logMetrics()
        task?.cancel(with: .normalClosure, reason: nil)
        resolveFinish()
        logger.info("ElevenLabs WebSocket connection closed")
    }

    /// Check if the client is currently connected.
    public var isConnected: Bool {
        currentWebSocketTask()?.state == .running
    }

    // MARK: - Private

    private func receiveMessages() {
        guard let task = currentWebSocketTask() else { return }
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessages()

            case .failure(let error):
                if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) {
                    return
                }
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                self.currentOnError()?(error)
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

    /// Feeds one raw provider frame through the receive path. The WebSocket
    /// loop is the only production caller; tests use it to drive the client
    /// without a live socket.
    func parseTranscriptResponse(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(ElevenLabsStreamResponse.self, from: data)

            guard let transcript = response.transcript, !transcript.isEmpty else {
                return
            }

            let isFinal = response.speechEventType == "FINAL_TRANSCRIPT"
            if isFinal {
                withStateLock { accumulated.append(final: transcript) }
                if resolveFinish() {
                    // Trailing final consumed by finishAndWait(), which returns
                    // the whole transcript; delivering it again through
                    // onTranscript would double it for callers that append.
                    return
                }
            }
            currentOnTranscript()?(transcript, isFinal)

        } catch {
            logger.debug("Failed to parse transcript response: \(error.localizedDescription)")
        }
    }

    /// Resumes a pending `finishAndWait()` exactly once with the session's full
    /// transcript. Returns whether a waiter consumed it.
    @discardableResult
    private func resolveFinish() -> Bool {
        finishLock.lock()
        let continuation = finishContinuation
        finishContinuation = nil
        finishLock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: fullTranscript())
        return true
    }

    private func fullTranscript() -> String? { withStateLock { accumulated.transcriptOrNil } }

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
    private let baseURL = URL(string: "https://api.elevenlabs.io/v1")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Validates that an ElevenLabs API key is valid and has Scribe speech-to-text access.
    public func validate(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "API key is empty")
        }

        let request = makeUserRequest(apiKey: trimmed)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "Received a non-HTTP response",
                    debug: debugSnapshot(request: request)
                )
            }

            let debug = debugSnapshot(request: request, response: http, data: data)
            guard http.statusCode != 401 else {
                return .failure(message: "Invalid API key", debug: debug)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
            }
        } catch {
            return .failure(
                message: "Validation failed: \(error.localizedDescription)",
                debug: debugSnapshot(request: request, error: error)
            )
        }

        return await validateScribeAccess(apiKey: trimmed)
    }

    private func makeUserRequest(apiKey: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("user")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func makeScribeProbeRequest(apiKey: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("speech-to-text")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            """
            --\(boundary)\r
            Content-Disposition: form-data; name="model_id"\r
            \r
            scribe_v1\r
            --\(boundary)--\r
            """.utf8
        )
        return request
    }

    private func validateScribeAccess(apiKey: String) async -> APIKeyValidationResult {
        let request = makeScribeProbeRequest(apiKey: apiKey)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "Received a non-HTTP response from Scribe",
                    debug: debugSnapshot(request: request)
                )
            }

            let debug = debugSnapshot(request: request, response: http, data: data)
            if http.statusCode == 403 {
                return .failure(
                    message: "API key does not have Scribe (speech-to-text) access. Use a key with both "
                        + "TTS and Scribe permissions.",
                    debug: debug
                )
            }
            if http.statusCode == 401 {
                return .failure(message: "Invalid API key", debug: debug)
            }
            if isAcceptedScribeProbeStatus(http.statusCode) {
                return .success(
                    message: "ElevenLabs API key is valid for Text-to-Speech and Scribe transcription",
                    debug: debug
                )
            }

            return .failure(message: "HTTP \(http.statusCode) while probing Scribe access", debug: debug)
        } catch {
            return .failure(
                message: "Scribe validation failed: \(error.localizedDescription)",
                debug: debugSnapshot(request: request, error: error)
            )
        }
    }

    private func isAcceptedScribeProbeStatus(_ statusCode: Int) -> Bool {
        (200..<300).contains(statusCode) || statusCode == 400 || statusCode == 415 || statusCode == 422
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
