// swiftlint:disable file_length
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
    let messageType: String
    private enum CodingKeys: String, CodingKey { case messageType = "message_type" }
}

private struct ElevenLabsTranscriptMessage: Decodable {
    let messageType: String
    let text: String?
    private enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case text
    }
}

private struct ElevenLabsErrorMessage: Decodable {
    let messageType: String
    let error: String?
    private enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case error
    }
}

// MARK: - Live Transcriber (WebSocket client)

// Streams raw PCM audio to ElevenLabs Scribe Realtime API and delivers partial/final
// transcript callbacks.
//
// Protocol reference: https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
// - URL: `wss://api.elevenlabs.io/v1/speech-to-text/realtime`
// - Auth: `xi-api-key` header
// - Audio: JSON `input_audio_chunk` messages with base64 PCM (NOT raw binary)
// - Commit: `commit_strategy=vad` keeps server-side VAD; manual `commit:true` flushes on stop
// swiftlint:disable type_body_length
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
    private var sessionStarted: Bool = false
    private var preStartAudioBuffer: [Data] = []
    private static let preStartByteLimit = 16_000 * 2 * 5 // 5s of 16kHz PCM16

    /// True after `sendCommit()` has been called; clears once the next
    /// `committed_transcript` arrives (or the await timeout fires).
    private var awaitingCommitFinal: Bool = false
    /// Continuation resumed by the next `committed_transcript` after a manual commit.
    private var commitContinuation: CheckedContinuation<Void, Never>?

    init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
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
            sessionStarted = false
            preStartAudioBuffer = []
            self.onTranscript = onTranscript
            self.onError = onError
        }
        connectWebSocket()
    }

    func sendAudio(_ audioData: Data) {
        // Buffer audio until session_started arrives so we don't lose the first words.
        let snapshot = withStateLock { () -> (URLSessionWebSocketTask?, Bool) in
            (webSocketTask, sessionStarted)
        }
        guard let task = snapshot.0, task.state == .running, snapshot.1 else {
            withStateLock {
                preStartAudioBuffer.append(audioData)
                var totalBytes = preStartAudioBuffer.reduce(0) { $0 + $1.count }
                while totalBytes > Self.preStartByteLimit, !preStartAudioBuffer.isEmpty {
                    totalBytes -= preStartAudioBuffer.removeFirst().count
                }
            }
            return
        }
        sendAudioFrame(audioData, on: task)
    }

    private func sendAudioFrame(_ audioData: Data, on task: URLSessionWebSocketTask) {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": audioData.base64EncodedString(),
            "sample_rate": sampleRate
        ]
        guard
            let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let text = String(data: json, encoding: .utf8)
        else { return }

        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.string(text)) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self else { return }
            if let error {
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
                self.logger.error("Failed to send audio: \(error.localizedDescription, privacy: .public)")
                self.currentOnError()?(error)
            }
        }
    }

    /// Flush any audio buffered before `session_started` arrived.
    private func flushPreStartAudio() {
        let (task, frames) = withStateLock { () -> (URLSessionWebSocketTask?, [Data]) in
            let pending = preStartAudioBuffer
            preStartAudioBuffer = []
            return (webSocketTask, pending)
        }
        guard let task, task.state == .running, !frames.isEmpty else { return }
        logger.info("Flushing \(frames.count) pre-start audio frames to ElevenLabs")
        for frame in frames {
            sendAudioFrame(frame, on: task)
        }
    }

    /// Send a manual commit to flush any pending VAD-buffered audio before stop.
    func sendCommit() {
        guard let task = currentWebSocketTask(), task.state == .running else { return }
        withStateLock { awaitingCommitFinal = true }
        let payload = #"{"message_type":"input_audio_chunk","audio_base_64":"","commit":true}"#
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.string(payload)) { _ in sendGroup.leave() }
    }

    /// Awaits the next `committed_transcript` after `sendCommit()`. Returns as soon
    /// as the server delivers the final, or after `timeout` seconds — whichever
    /// comes first. Both paths nil-out the continuation so resume is idempotent.
    func awaitCommitFinal(timeout: TimeInterval = 1.5) async {
        // If we never sent a commit (or already received one), return immediately.
        let needsWait = withStateLock { awaitingCommitFinal }
        guard needsWait else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldWait = withStateLock { () -> Bool in
                guard awaitingCommitFinal else { return false }
                commitContinuation = continuation
                return true
            }
            if !shouldWait {
                continuation.resume()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                let pending = self.withStateLock { () -> CheckedContinuation<Void, Never>? in
                    let saved = self.commitContinuation
                    self.commitContinuation = nil
                    self.awaitingCommitFinal = false
                    return saved
                }
                pending?.resume()
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

        // Resume any in-flight commit awaiter so callers don't deadlock on stop().
        let pending = withStateLock { () -> CheckedContinuation<Void, Never>? in
            let saved = commitContinuation
            commitContinuation = nil
            awaitingCommitFinal = false
            return saved
        }
        pending?.resume()

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
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "vad")
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

        logger.info("ElevenLabs WebSocket connecting (model: \(self.modelID, privacy: .public))")
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
                self.logger.error("WebSocket receive error: \(error.localizedDescription, privacy: .public)")
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

    // swiftlint:disable:next cyclomatic_complexity
    private func parseResponse(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        do {
            let envelope = try JSONDecoder().decode(ElevenLabsStreamEnvelope.self, from: data)
            switch envelope.messageType {
            case "session_started":
                logger.info("ElevenLabs session started")
                withStateLock { sessionStarted = true }
                flushPreStartAudio()

            case "partial_transcript":
                let msg = try JSONDecoder().decode(ElevenLabsTranscriptMessage.self, from: data)
                guard let text = msg.text, !text.isEmpty else { return }
                currentOnTranscript()?(text, false)

            case "committed_transcript", "committed_transcript_with_timestamps":
                let msg = try JSONDecoder().decode(ElevenLabsTranscriptMessage.self, from: data)
                if let text = msg.text, !text.isEmpty {
                    currentOnTranscript()?(text, true)
                }
                // If a manual commit (sent during stop) is being awaited, resume
                // the continuation so the HUD doesn't sit on "Finalising".
                let pending = withStateLock { () -> CheckedContinuation<Void, Never>? in
                    guard awaitingCommitFinal else { return nil }
                    awaitingCommitFinal = false
                    let saved = commitContinuation
                    commitContinuation = nil
                    return saved
                }
                pending?.resume()

            case "auth_error":
                logger.error("ElevenLabs auth error: \(json.prefix(200), privacy: .public)")
                currentOnError()?(ElevenLabsLiveError.invalidAPIKeyOrMissingScribeAccess)

            case "input_error", "transcriber_error", "rate_limited",
                 "quota_exceeded", "queue_overflow", "resource_exhausted",
                 "session_time_limit_exceeded", "chunk_size_exceeded",
                 "insufficient_audio_activity", "commit_throttled", "unaccepted_terms":
                let err = try? JSONDecoder().decode(ElevenLabsErrorMessage.self, from: data)
                let detail = err?.error ?? envelope.messageType
                let kind = envelope.messageType
                logger.error("ElevenLabs server error (\(kind, privacy: .public)): \(detail, privacy: .public)")
                currentOnError()?(NSError(
                    domain: "ElevenLabs", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "ElevenLabs: \(detail)"]
                ))

            case "session_closed":
                logger.info("ElevenLabs server closed session")

            default:
                logger.debug("Unhandled ElevenLabs message type: \(envelope.messageType, privacy: .public)")
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

// swiftlint:enable type_body_length
