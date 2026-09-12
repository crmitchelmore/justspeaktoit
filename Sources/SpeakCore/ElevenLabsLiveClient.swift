// swiftlint:disable file_length
import Foundation
import os.log

// MARK: - ElevenLabs Live Client (Cross-platform WebSocket)

/// Cross-platform ElevenLabs WebSocket client for live speech-to-text.
public final class ElevenLabsLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .standaloneSegments

    struct Timing: Sendable {
        let readiness: TimeInterval
        let postCommitDrain: TimeInterval
        let overall: TimeInterval

        static let production = Timing(readiness: 2, postCommitDrain: 1.5, overall: 4)
    }

    private struct Outbound {
        let message: URLSessionWebSocketTask.Message
        let audioBytes: Int
        let isCommit: Bool
    }

    private final class Run: @unchecked Sendable {
        let id = UUID()
        let socket: LiveWebSocketTransport
        var ready = false
        var finishing = false
        var completed = false
        var sending = false
        var outbound: [Outbound] = []
        var waiters: [CheckedContinuation<String?, Never>] = []
        var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
        let sendBudget: StreamingAudioSendBudget
        let onTranscript: (String, Bool) -> Void
        let onError: (Error) -> Void

        init(
            socket: LiveWebSocketTransport,
            sampleRate: Int,
            onTranscript: @escaping (String, Bool) -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.socket = socket
            self.sendBudget = StreamingAudioSendBudget(sampleRate: sampleRate)
            self.onTranscript = onTranscript
            self.onError = onError
        }
    }

    private let apiKey: String
    private let modelID: String
    private let language: String?
    private let sampleRate: Int
    private let socketFactory: LiveWebSocketFactory
    private let timing: Timing
    private let logger = SpeakLogger.logger(category: "ElevenLabsLiveClient")
    private let queue = DispatchQueue(label: "ElevenLabsLiveClient.session")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let callbackQueue = DispatchQueue(label: "ElevenLabsLiveClient.callbacks")
    private static let errorMessageTypes: Set<String> = [
        "error", "auth_error", "quota_exceeded", "throttled", "unaccepted_terms",
        "rate_limited", "queue_overflow", "resource_exhausted", "session_time_limit_exceeded",
        "input_error", "invalid_request", "chunk_size_exceeded", "insufficient_audio_activity",
        "transcriber_error"
    ]
    private var run: Run?
    private var lastTranscript: String?
    private var callbackRunID: UUID?
    private var acceptsPrestartAudio = true
    let preroll: StreamingAudioPreroll

    public init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
        language: String? = nil,
        sampleRate: Int = LiveTranscriptionProviderID.elevenlabs.expectedSampleRate,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.language = language
        self.sampleRate = sampleRate
        self.socketFactory = { request in
            URLSessionLiveWebSocketTransport(task: session.webSocketTask(with: request))
        }
        self.timing = .production
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
        language: String? = nil,
        sampleRate: Int = LiveTranscriptionProviderID.elevenlabs.expectedSampleRate,
        timing: Timing,
        socketFactory: @escaping LiveWebSocketFactory
    ) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.language = language
        self.sampleRate = sampleRate
        self.socketFactory = socketFactory
        self.timing = timing
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    func makeRequest() -> URLRequest? {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "vad")
        ]
        if let language { items.append(URLQueryItem(name: "language_code", value: language.localeLanguageCode)) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard let request = makeRequest() else {
            onError(ElevenLabsLiveError.invalidURL)
            return
        }
        let socket = socketFactory(request)
        queue.async { [weak self] in
            guard let self else { return }
            if let previous = self.run { self.complete(previous, closeCode: .goingAway) }
            self.lastTranscript = nil
            self.acceptsPrestartAudio = false
            self.preroll.reset()
            let current = Run(
                socket: socket, sampleRate: self.sampleRate,
                onTranscript: onTranscript, onError: onError
            )
            self.run = current
            self.callbackRunID = current.id
            socket.resume()
            self.receive(on: current)
        }
    }

    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        withQueueLock {
            guard let current = run else {
                if acceptsPrestartAudio { preroll.append(audioData) }
                return
            }
            guard !current.finishing, !current.completed else { return }
            guard current.ready else {
                preroll.append(audioData)
                return
            }
            enqueueAudio(audioData, on: current)
        }
    }

    public func sendAudioSamples(_ samples: UnsafePointer<Float>, frameCount: Int) {
        sendAudio(PCM16Converter.data(from: samples, frameCount: frameCount))
    }

    public var finishFlushesBufferedAudio: Bool { true }

    public func finishAndWait() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let current = self.run else {
                    continuation.resume(returning: self?.lastTranscript)
                    return
                }
                guard !current.completed else {
                    continuation.resume(returning: current.accumulated.transcriptOrNil)
                    return
                }
                current.waiters.append(continuation)
                if current.socket.state == .completed || current.socket.state == .canceling {
                    self.complete(current, closeCode: .normalClosure)
                    return
                }
                guard !current.finishing else { return }
                current.finishing = true
                self.scheduleDeadline(for: current, after: self.timing.overall)
                if current.ready {
                    self.flushAndCommit(current)
                } else {
                    self.scheduleReadinessDeadline(for: current)
                }
            }
        }
    }

    public func stop() {
        withQueueLock {
            acceptsPrestartAudio = false
            guard let current = run else {
                preroll.reset()
                return
            }
            complete(current, closeCode: .normalClosure)
        }
    }

    public var isConnected: Bool {
        withQueueLock { run?.socket.state == .running }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            run?.socket.cancel(with: .goingAway, reason: nil)
        } else {
            queue.sync { run?.socket.cancel(with: .goingAway, reason: nil) }
        }
    }
}

extension ElevenLabsLiveClient {
    private func receive(on current: Run) {
        current.socket.receive { [weak self, weak current] result in
            guard let self, let current else { return }
            self.queue.async {
                guard self.isActive(current) else { return }
                switch result {
                case .success(let message):
                    self.handle(message, on: current)
                    if self.isActive(current) { self.receive(on: current) }
                case .failure(let error):
                    if !WebSocketErrorFilter.shouldIgnore(error) { self.emitError(error, on: current) }
                    self.complete(current, closeCode: .goingAway)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, on current: Run) {
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text,
              let data = text.data(using: .utf8),
              let response = try? JSONDecoder().decode(ElevenLabsStreamResponse.self, from: data) else { return }

        if let messageType = response.messageType, Self.errorMessageTypes.contains(messageType) {
            emitError(providerError(response), on: current)
            complete(current, closeCode: .goingAway)
            return
        }

        switch response.messageType {
        case "session_started":
            guard !current.ready else { return }
            current.ready = true
            let held = preroll.drain()
            for chunk in held { enqueueAudio(chunk, on: current) }
            if current.finishing { enqueueCommit(on: current) }
        case "partial_transcript":
            guard let text = response.text, !text.isEmpty, !current.finishing else { return }
            emitTranscript(text, isFinal: false, on: current)
        case "committed_transcript":
            guard let text = response.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            current.accumulated.append(final: text)
            if !current.finishing { emitTranscript(text, isFinal: true, on: current) }
        case "committed_transcript_with_timestamps":
            break
        default:
            break
        }
    }

    /// Fixture entry point for the real provider event decoder.
    func parseTranscriptResponse(_ json: String) {
        queue.sync {
            guard let current = run else { return }
            handle(.string(json), on: current)
        }
    }

    private func flushAndCommit(_ current: Run) {
        for chunk in preroll.drain() { enqueueAudio(chunk, on: current) }
        enqueueCommit(on: current)
    }

    private func enqueueAudio(_ data: Data, on current: Run) {
        guard current.sendBudget.admit(data.count) else {
            emitError(ElevenLabsLiveError.sendFailed, on: current)
            complete(current, closeCode: .goingAway)
            return
        }
        guard let message = Self.audioMessage(data, sampleRate: sampleRate, commit: false) else {
            current.sendBudget.release(data.count)
            return
        }
        current.outbound.append(Outbound(message: message, audioBytes: data.count, isCommit: false))
        pump(current)
    }

    private func enqueueCommit(on current: Run) {
        guard !current.outbound.contains(where: \.isCommit),
              let message = Self.audioMessage(Data(), sampleRate: sampleRate, commit: true) else { return }
        current.outbound.append(Outbound(message: message, audioBytes: 0, isCommit: true))
        pump(current)
    }

    private func pump(_ current: Run) {
        guard isActive(current), !current.sending, !current.outbound.isEmpty else { return }
        current.sending = true
        let outbound = current.outbound.removeFirst()
        current.socket.send(outbound.message) { [weak self, weak current] error in
            guard let self, let current else { return }
            self.queue.async {
                guard self.isActive(current) else { return }
                current.sendBudget.release(outbound.audioBytes)
                current.sending = false
                if let error {
                    self.emitError(error, on: current)
                    self.complete(current, closeCode: .goingAway)
                    return
                }
                if outbound.isCommit {
                    self.scheduleDeadline(for: current, after: self.timing.postCommitDrain)
                }
                self.pump(current)
            }
        }
    }

    static func audioMessage(_ data: Data, sampleRate: Int, commit: Bool) -> URLSessionWebSocketTask.Message? {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": data.base64EncodedString(),
            "sample_rate": sampleRate,
            "commit": commit
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: encoded, encoding: .utf8) else { return nil }
        return .string(text)
    }

    private func scheduleReadinessDeadline(for current: Run) {
        queue.asyncAfter(deadline: .now() + timing.readiness) { [weak self, weak current] in
            guard let self, let current, self.isActive(current), !current.ready else { return }
            self.complete(current, closeCode: .goingAway)
        }
    }

    private func scheduleDeadline(for current: Run, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self, weak current] in
            guard let self, let current, self.isActive(current) else { return }
            self.complete(current, closeCode: .normalClosure)
        }
    }

    private func complete(_ current: Run, closeCode: URLSessionWebSocketTask.CloseCode) {
        guard !current.completed else { return }
        current.completed = true
        if run === current { run = nil }
        preroll.reset()
        current.socket.cancel(with: closeCode, reason: nil)
        let transcript = current.accumulated.transcriptOrNil
        lastTranscript = transcript
        acceptsPrestartAudio = false
        let waiters = current.waiters
        current.waiters = []
        waiters.forEach { $0.resume(returning: transcript) }
    }

    private func isActive(_ current: Run) -> Bool { run === current && !current.completed }

    private func withQueueLock<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return operation() }
        return queue.sync(execute: operation)
    }

    private func emitTranscript(_ text: String, isFinal: Bool, on current: Run) {
        let id = current.id
        let callback = current.onTranscript
        callbackQueue.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.callbackRunID == id }) else { return }
            callback(text, isFinal)
        }
    }

    private func emitError(_ error: Error, on current: Run) {
        let id = current.id
        let callback = current.onError
        callbackQueue.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.callbackRunID == id }) else { return }
            callback(error)
        }
    }

    private func providerError(_ response: ElevenLabsStreamResponse) -> Error {
        let message = response.error ?? response.text ?? "ElevenLabs realtime error"
        if message.lowercased().contains("auth") || message.contains("401") || message.contains("403") {
            return ElevenLabsLiveError.missingAPIKey
        }
        return NSError(domain: "ElevenLabs", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct ElevenLabsStreamResponse: Decodable {
    let messageType: String?
    let text: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case text
        case error
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
    /// Batch Scribe model used for the access probe. ElevenLabs removed
    /// `scribe_v1` on 2026-07-09, so probing with it now fails for every key.
    public static let defaultProbeModelID = "scribe_v2"

    private let session: URLSession
    private let modelID: String
    private let baseURL = URL(string: "https://api.elevenlabs.io/v1")!

    public init(
        session: URLSession = .shared,
        modelID: String = ElevenLabsSTTAPIKeyValidator.defaultProbeModelID
    ) {
        self.session = session
        self.modelID = modelID
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
            \(modelID)\r
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
