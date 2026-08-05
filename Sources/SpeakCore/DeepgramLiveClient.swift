// swiftlint:disable file_length
import Foundation
import os.log

// MARK: - Deepgram Live Client (Cross-platform WebSocket)

/// Cross-platform Deepgram WebSocket client for live transcription.
/// Works on both macOS and iOS.
public final class DeepgramLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let bufferPool: AudioBufferPool
    private let logger = Logger(subsystem: "com.speak.app", category: "DeepgramLiveClient")
    private let stateLock = NSLock()

    // Guarded by `stateLock`: mutated by the caller while URLSession callbacks read them.
    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false

    /// Bounded post-stop drain state: after `CloseStream` is sent, the trailing
    /// final transcript is handed to the awaiting `finishAndWait()` instead of
    /// `onTranscript`, so the caller appends it exactly once.
    private let finishLock = NSLock()
    private var finishContinuation: CheckedContinuation<String?, Never>?
    private static let finishDrainBudget: TimeInterval = 1.0

    public init(
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
    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            isStopping = false
            self.onTranscript = onTranscript
            self.onError = onError
        }

        var urlComponents = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "numerals", value: "true"),
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
            onError(DeepgramLiveError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

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

        logger.info("Deepgram WebSocket connection started")
        receiveMessages()
    }

    /// Sends raw audio data to the transcription service.
    /// - Parameter audioData: Raw audio data in linear16 format.
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
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) {
                    return
                }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.currentOnError()?(error)
            }
        }
    }

    /// Sends Float32 audio samples converted to Int16 linear PCM.
    /// - Parameters:
    ///   - samples: Array of Float32 audio samples (-1.0 to 1.0).
    ///   - frameCount: Number of frames to send.
    public func sendAudioSamples(_ samples: UnsafePointer<Float>, frameCount: Int) {
        var buffer = bufferPool.checkout()
        buffer.reserveCapacity(frameCount * MemoryLayout<Int16>.size)

        // Single-pass Float32 → Int16 conversion into a preallocated array,
        // appended in one bulk copy instead of 2 bytes per sample.
        var int16Samples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = samples[i]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Samples[i] = Int16(clampedSample * Float(Int16.max)).littleEndian
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
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) {
                    return
                }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.currentOnError()?(error)
            }
        }
    }

    /// Graceful stop: asks Deepgram to flush buffered audio with a
    /// `CloseStream` frame, waits (bounded) for the trailing final transcript,
    /// then closes the socket — so words spoken just before stop aren't lost.
    ///
    /// Returns a final transcript segment that was *not* delivered through
    /// `onTranscript`, or `nil` when nothing new arrived within the budget.
    public func finishAndWait() async -> String? {
        guard let task = currentWebSocketTask(), task.state == .running else {
            stop()
            return nil
        }

        let transcript: String? = await withCheckedContinuation { continuation in
            finishLock.lock()
            finishContinuation = continuation
            finishLock.unlock()

            // Deepgram flushes and finalises any buffered audio on CloseStream.
            // A send failure just means the socket is already gone; the bounded
            // wait below still resolves via the timeout.
            task.send(.string(#"{"type":"CloseStream"}"#)) { _ in }

            DispatchQueue.global().asyncAfter(deadline: .now() + Self.finishDrainBudget) { [weak self] in
                self?.resolveFinish(with: nil)
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
        resolveFinish(with: nil)
        logger.info("Deepgram WebSocket connection closed")
    }

    /// Check if the client is currently connected.
    public var isConnected: Bool {
        currentWebSocketTask()?.state == .running
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
        guard let task = currentWebSocketTask() else { return }
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessages()

            case .failure(let error):
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) {
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

    private func parseTranscriptResponse(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(DeepgramStreamResponse.self, from: data)

            // After CloseStream, Metadata is the stream's last message — stop
            // waiting even when no trailing final transcript arrived.
            if response.type == "Metadata" {
                resolveFinish(with: nil)
                return
            }

            guard let channel = response.channel,
                  let alternative = channel.alternatives.first,
                  !alternative.transcript.isEmpty else {
                return
            }

            let isFinal = response.is_final ?? false
            if isFinal, resolveFinish(with: alternative.transcript) {
                // Trailing final consumed by finishAndWait(); don't also
                // deliver it through onTranscript.
                return
            }
            currentOnTranscript()?(alternative.transcript, isFinal)

        } catch {
            logger.debug("Failed to parse transcript response: \(error.localizedDescription)")
        }
    }

    /// Resumes a pending `finishAndWait()` exactly once. Returns whether a
    /// waiter consumed the value.
    @discardableResult
    private func resolveFinish(with transcript: String?) -> Bool {
        finishLock.lock()
        let continuation = finishContinuation
        finishContinuation = nil
        finishLock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: transcript)
        return true
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
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

// MARK: - Response Models

private struct DeepgramStreamResponse: Decodable {
    struct Channel: Decodable {
        struct Alternative: Decodable {
            let transcript: String
            let confidence: Double?
        }

        let alternatives: [Alternative]
    }

    let type: String?
    let channel: Channel?
    let is_final: Bool?
}

// MARK: - Error Types

public enum DeepgramLiveError: LocalizedError {
    case invalidURL
    case connectionFailed
    case sendFailed
    case missingAPIKey

    public var errorDescription: String? {
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

// MARK: - API Key Validation

public struct DeepgramAPIKeyValidator {
    private let session: URLSession
    
    public init(session: URLSession = .shared) {
        self.session = session
    }
    
    /// Validates a Deepgram API key by making a test request.
    public func validate(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "API key is empty")
        }

        let url = URL(string: "https://api.deepgram.com/v1/projects")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Received a non-HTTP response")
            }

            if (200..<300).contains(http.statusCode) {
                return .success(message: "Deepgram API key validated")
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            return .failure(message: "HTTP \(http.statusCode): \(body)")
        } catch {
            return .failure(message: "Validation failed: \(error.localizedDescription)")
        }
    }
}
