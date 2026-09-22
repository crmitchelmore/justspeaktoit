// swiftlint:disable file_length
import AVFoundation
import Foundation
import os.log
import SpeakCore

// MARK: - Errors

enum SonioxLiveError: LocalizedError {
    case missingAPIKey
    case invalidURLComponents
    case connectionFailed
    case invalidAPIKey
    case batchNotSupported
    case transcriptionFailed(String)
    case transcriptionTimedOut

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Soniox API key is missing. Please add it in Settings → Soniox."
        case .invalidURLComponents:
            return "Failed to construct Soniox WebSocket URL."
        case .connectionFailed:
            return "Failed to establish WebSocket connection to Soniox."
        case .invalidAPIKey:
            return "Soniox API key is invalid. Check your key in Settings → Soniox."
        case .batchNotSupported:
            return "Soniox is currently only available for live streaming in Speak."
        case .transcriptionFailed(let message):
            return "Soniox transcription failed: \(message)"
        case .transcriptionTimedOut:
            return "Soniox transcription did not complete in time."
        }
    }
}

// MARK: - WebSocket response types

private struct SonioxToken: Decodable {
    let text: String
    let isFinal: Bool?
    private enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}

private struct SonioxStreamResponse: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: Int?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

protocol SonioxFinalizationDelegate: AnyObject {
    /// Soniox emitted a `finished: true` signal — caller should release any pending stop().
    func sonioxDidFinishStream(_ transcriber: SonioxLiveTranscriber)
}

// MARK: - Provider

// Soniox v5 supports real-time streaming and asynchronous batch transcription.
struct SonioxTranscriptionProvider: TranscriptionProvider {
    private let client: SonioxBatchClient
    var metadata: TranscriptionProviderMetadata { client.metadata }

    init(
        session: URLSession = .shared,
        pollingDelay: Duration = .seconds(2),
        maximumPollingAttempts: Int = 90,
        multipartStaging: MultipartUploadStaging = .shared
    ) {
        let logger = SpeakLogger.logger(category: "SonioxTranscriptionProvider")
        client = SonioxBatchClient(
            session: session, pollingDelay: pollingDelay, maximumPollingAttempts: maximumPollingAttempts,
            multipartStaging: multipartStaging.sharedStore,
            reportCleanupFailure: { message in
                logger.error("Failed to clean up Soniox async resources: \(message, privacy: .public)")
            }
        )
    }

    func transcribeFile(
        at url: URL, apiKey: String, model: String, language: String?
    ) async throws -> TranscriptionResult {
        do {
            return try await client.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
        } catch let error as SonioxBatchError {
            switch error {
            case .unsupportedModel: throw SonioxLiveError.batchNotSupported
            case .transcriptionFailed(let message): throw SonioxLiveError.transcriptionFailed(message)
            case .transcriptionTimedOut: throw SonioxLiveError.transcriptionTimedOut
            }
        }
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult { await client.validateAPIKey(key) }
    func requiresAPIKey(for model: String) -> Bool { client.requiresAPIKey(for: model) }
    func supportedModels() -> [ModelCatalog.Option] {
        ModelCatalog.liveTranscriptionOptions(forProvider: metadata.id) + client.supportedModels()
    }
}

// MARK: - Live Transcriber (WebSocket client)

// swiftlint:disable type_body_length
final class SonioxLiveTranscriber: @unchecked Sendable {
    private static let websocketHost = "stt-rt.soniox.com"
    private static let websocketPath = "/transcribe-websocket"

    /// Upper bound on how long a close waits for queued frames to reach the
    /// transport; a wedged send must never leave the socket open forever.
    private static let stopFlushBudget: DispatchTimeInterval = .milliseconds(750)

    /// Preferred PCM chunk size: 100 ms at 16 kHz PCM16 mono.
    static let preferredChunkBytes = 3_200
    static let minimumChunkBytes = 1_600

    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let logger = SpeakLogger.logger(category: "SonioxLiveTranscriber")
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false
    private var didSendConfig: Bool = false
    /// Cumulative final-token text. Soniox sends each final token exactly once;
    /// we accumulate them so the live transcript grows monotonically instead of
    /// being clobbered by per-batch emits.
    private var accumulatedFinalText: String = ""
    weak var finalizationDelegate: SonioxFinalizationDelegate?

    /// Holds audio captured between the recording cue and the socket reaching
    /// `.running`, then replays it in order (issue #641).
    let preroll: StreamingAudioPreroll

    init(
        apiKey: String,
        model: String = "stt-rt-v5",
        language: String? = nil,
        sampleRate: Int = 16000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.session = session
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
    }

    func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            isStopping = false
            didSendConfig = false
            accumulatedFinalText = ""
            self.onTranscript = onTranscript
            self.onError = onError
        }
        preroll.reset()
        connectWebSocket()
    }

    /// Sends raw PCM Int16 audio data to Soniox.
    ///
    /// Audio captured before the socket is running is parked in the pre-roll
    /// buffer and replayed, in order, on the first send that finds a live
    /// transport — so speech that starts with the cue is never dropped.
    func sendAudio(_ audioData: Data) {
        guard let task = currentWebSocketTask(), task.state == .running else {
            guard !isStoppingState() else { return }
            preroll.append(audioData)
            return
        }
        flushPreroll(on: task)
        transmit(.data(audioData), on: task)
    }

    /// Soniox graceful close: send an empty binary frame to flush the final tokens.
    func signalEndOfStream() {
        guard let task = currentWebSocketTask(), task.state == .running else { return }
        flushPreroll(on: task)
        transmit(.data(Data()), on: task)
    }

    /// Send Soniox `{"type":"finalize"}` to force any in-flight non-final tokens
    /// to be returned as final tokens. Must be called *before* `signalEndOfStream`
    /// so the server has a chance to finalize before closing.
    func sendFinalize() {
        guard let task = currentWebSocketTask(), task.state == .running else { return }
        flushPreroll(on: task)
        transmit(.string(#"{"type":"finalize"}"#), on: task)
    }

    /// Closes the session, but never before the frames already handed to the
    /// transport have left it.
    ///
    /// `cancel(with:reason:)` fails whatever URLSession has not yet written, so
    /// cancelling here would discard the `finalize` and end-of-stream frames the
    /// controller sends immediately before calling this — and with them the
    /// trailing final tokens. The close therefore waits (bounded, off the
    /// caller's thread) for `pendingSendGroup` to drain first.
    func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            return webSocketTask
        }
        guard let task else {
            preroll.reset()
            return
        }
        let unsentPreroll = preroll.snapshot
        if unsentPreroll.byteCount > 0 {
            logger.warning(
                "Soniox: discarding \(unsentPreroll.chunkCount) pre-roll chunks — transport never became ready"
            )
        }
        preroll.reset()
        closeAfterPendingSends(task)
    }

    private func closeAfterPendingSends(_ task: URLSessionWebSocketTask) {
        let sendGroup = pendingSendGroup
        let logger = self.logger
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if sendGroup.wait(timeout: .now() + Self.stopFlushBudget) == .timedOut {
                logger.warning("Soniox: closing with sends still in flight after the stop flush budget")
            }
            if task.state == .running {
                task.cancel(with: .normalClosure, reason: nil)
            }
            self?.clearWebSocketTask(task)
            logger.info("Soniox WebSocket connection closed")
        }
    }

    /// Only the task this stop owns may be cleared: a newer session may already
    /// have published its own socket.
    private func clearWebSocketTask(_ task: URLSessionWebSocketTask) {
        withStateLock {
            if webSocketTask === task { webSocketTask = nil }
        }
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

    /// Replays audio captured before the transport was ready, in capture order,
    /// ahead of whatever frame prompted the flush.
    private func flushPreroll(on task: URLSessionWebSocketTask) {
        let held = preroll.drain()
        guard !held.isEmpty else { return }
        let bytes = held.reduce(0) { $0 + $1.count }
        let leadingMilliseconds = Int((Double(bytes) / 2.0 / Double(max(sampleRate, 1))) * 1000)
        logger.info(
            "Soniox: replaying \(held.count) pre-roll chunks (\(leadingMilliseconds) ms of leading audio)"
        )
        for chunk in held {
            transmit(.data(chunk), on: task)
        }
    }

    /// Every frame — audio, replayed pre-roll and the finalize handshake — goes
    /// through here so `waitForPendingSends()` covers it.
    private func transmit(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(message) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self, let error else { return }
            if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
            self.logger.error("Failed to send audio: \(error.localizedDescription)")
            self.currentOnError()?(error)
        }
    }

    private func connectWebSocket() {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = Self.websocketHost
        components.path = Self.websocketPath
        guard let url = components.url else {
            currentOnError()?(SonioxLiveError.invalidURLComponents)
            return
        }

        let task = session.webSocketTask(with: url)
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

        sendInitialConfig()
        logger.info("Soniox WebSocket connecting (model=\(self.model, privacy: .public))")
        receiveMessages()
    }

    private func sendInitialConfig() {
        guard let task = currentWebSocketTask() else { return }
        let payload = Self.initialConfigPayload(
            apiKey: apiKey,
            model: model,
            language: language,
            sampleRate: sampleRate
        )
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.string(json)) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self else { return }
            if let error {
                if self.isStoppingState() { return }
                self.currentOnError()?(error)
                return
            }
            self.withStateLock { self.didSendConfig = true }
        }
    }

    static func initialConfigPayload(
        apiKey: String,
        model: String,
        language: String?,
        sampleRate: Int
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": 1
        ]
        if let language {
            payload["language_hints"] = [language.localeLanguageCode]
        }
        return payload
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
                if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
                self.logger.error("Soniox receive error: \(error.localizedDescription)")
                self.currentOnError()?(self.mapConnectionError(error))
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text): parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) { parseResponse(text) }
        @unknown default: break
        }
    }

    /// Soniox tokens carry their own whitespace inside `text`; we accumulate
    /// finals into a running buffer and emit `(accumulated + non_final, false)`
    /// for every batch. The cumulative final commit is fired by `flushFinal()`.
    private func parseResponse(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        do {
            let response = try JSONDecoder().decode(SonioxStreamResponse.self, from: data)
            if let code = response.errorCode {
                let message = response.errorMessage ?? "Soniox error \(code)"
                logger.error("Soniox server error \(code): \(message, privacy: .public)")
                currentOnError()?(NSError(
                    domain: "Soniox", code: code,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
                return
            }

            let tokens = response.tokens ?? []
            if !tokens.isEmpty {
                var newFinals = ""
                var nonFinals = ""
                var sawFinalizationMarker = false
                for token in tokens {
                    // Soniox emits `<fin>` to acknowledge a manual `finalize` request
                    // and `<end>` when the session is fully finished. Don't display
                    // them; treat both as a signal that buffered finals are committed.
                    if token.text == "<fin>" || token.text == "<end>" {
                        sawFinalizationMarker = true
                        continue
                    }
                    if token.isFinal == true {
                        newFinals.append(token.text)
                    } else {
                        nonFinals.append(token.text)
                    }
                }

                let display: String = withStateLock {
                    accumulatedFinalText.append(newFinals)
                    return accumulatedFinalText + nonFinals
                }
                let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    currentOnTranscript()?(trimmed, false)
                }

                if sawFinalizationMarker {
                    flushFinal()
                    finalizationDelegate?.sonioxDidFinishStream(self)
                }
            }

            if response.finished == true {
                flushFinal()
                finalizationDelegate?.sonioxDidFinishStream(self)
            }
        } catch {
            logger.debug("Failed to parse Soniox response: \(error.localizedDescription)")
        }
    }

    /// Emit the accumulated final transcript as a single `(text, true)` callback.
    /// Safe to call multiple times — second call is a no-op.
    func flushFinal() {
        let text: String? = withStateLock {
            let snapshot = accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
            accumulatedFinalText = ""
            return snapshot.isEmpty ? nil : snapshot
        }
        if let text {
            currentOnTranscript()?(text, true)
        }
    }

    private func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return SonioxLiveError.invalidAPIKey
        }
        return error
    }

    private func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    private func currentWebSocketTask() -> URLSessionWebSocketTask? {
        withStateLock { webSocketTask }
    }

    private func isStoppingState() -> Bool {
        withStateLock { isStopping }
    }

    private func currentOnTranscript() -> ((String, Bool) -> Void)? {
        withStateLock { onTranscript }
    }

    private func currentOnError() -> ((Error) -> Void)? {
        withStateLock { onError }
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
