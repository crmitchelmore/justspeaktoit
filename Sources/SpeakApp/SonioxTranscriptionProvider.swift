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
    func sonioxDidFinishStream()
}

// MARK: - Provider

/// Soniox Real-time STT v2 streaming. Live-only — batch is not implemented in this build.
struct SonioxTranscriptionProvider: TranscriptionProvider {
    let metadata = TranscriptionProviderMetadata(
        id: "soniox",
        displayName: "Soniox",
        systemImage: "waveform.badge.magnifyingglass",
        tintColor: "indigo",
        website: "https://soniox.com"
    )

    private let session: URLSession
    private let baseURL = URL(string: "https://api.soniox.com/v1")!
    private let pollingDelay: Duration
    private let maximumPollingAttempts: Int

    init(
        session: URLSession = .shared,
        pollingDelay: Duration = .seconds(2),
        maximumPollingAttempts: Int = 90
    ) {
        self.session = session
        self.pollingDelay = pollingDelay
        self.maximumPollingAttempts = maximumPollingAttempts
    }

    func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        guard model == "soniox/stt-async-v5" else {
            throw SonioxLiveError.batchNotSupported
        }

        let file = try await uploadFile(at: url, apiKey: apiKey)
        let transcription = try await createTranscription(
            fileID: file.id,
            apiKey: apiKey,
            language: language
        )
        let completed = try await waitForCompletion(id: transcription.id, apiKey: apiKey)
        let transcript = try await fetchTranscript(id: completed.id, apiKey: apiKey)
        return buildTranscriptionResult(
            transcript: transcript,
            transcription: completed,
            model: model
        )
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "Empty API key")
        }
        // Lightweight validation: hit the temporary-key endpoint with a tiny duration.
        guard let url = URL(string: "https://api.soniox.com/v1/auth/temporary-api-key") else {
            return .failure(message: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"usage_type":"transcribe_websocket","expires_in_seconds":60}"#.utf8)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Non-HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .success(message: "Soniox API key validated")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(message: "Soniox rejected the key (HTTP \(http.statusCode))")
            }
            return .failure(message: "HTTP \(http.statusCode) while validating key")
        } catch {
            return .failure(message: "Validation failed: \(error.localizedDescription)")
        }
    }

    func requiresAPIKey(for model: String) -> Bool { true }

    func supportedModels() -> [ModelCatalog.Option] {
        [
            ModelCatalog.Option(
                id: "soniox/stt-rt-v5-streaming",
                displayName: "Soniox Real-time v5",
                description: "Soniox v5 real-time streaming transcription."
            ),
            ModelCatalog.Option(
                id: "soniox/stt-async-v5",
                displayName: "Soniox Async v5",
                description: "Soniox v5 asynchronous batch transcription with speaker and language metadata."
            )
        ]
    }

    private func uploadFile(at url: URL, apiKey: String) async throws -> SonioxFile {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("files"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendFileField(
            named: "file",
            filename: url.lastPathComponent,
            mimeType: mimeType(for: url),
            fileData: try Data(contentsOf: url),
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let data = try await send(request)
        return try JSONDecoder().decode(SonioxFile.self, from: data)
    }

    private func createTranscription(
        fileID: String,
        apiKey: String,
        language: String?
    ) async throws -> SonioxTranscription {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = SonioxCreateTranscriptionPayload(
            model: "stt-async-v5",
            fileID: fileID,
            languageHints: language.map { [extractLanguageCode(from: $0)] },
            enableSpeakerDiarization: true,
            enableLanguageIdentification: true
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await send(request, expectedStatusCodes: 200..<300)
        return try JSONDecoder().decode(SonioxTranscription.self, from: data)
    }

    private func waitForCompletion(id: String, apiKey: String) async throws -> SonioxTranscription {
        for _ in 0..<maximumPollingAttempts {
            let transcription = try await fetchTranscription(id: id, apiKey: apiKey)
            switch transcription.status {
            case "completed":
                return transcription
            case "error":
                throw SonioxLiveError.transcriptionFailed(
                    transcription.errorMessage ?? transcription.errorType ?? "Unknown error"
                )
            default:
                try await Task.sleep(for: pollingDelay)
            }
        }
        throw SonioxLiveError.transcriptionTimedOut
    }

    private func fetchTranscription(id: String, apiKey: String) async throws -> SonioxTranscription {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcriptions/\(id)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        return try JSONDecoder().decode(SonioxTranscription.self, from: data)
    }

    private func fetchTranscript(id: String, apiKey: String) async throws -> SonioxTranscript {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcriptions/\(id)/transcript"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        return try JSONDecoder().decode(SonioxTranscript.self, from: data)
    }

    private func send(
        _ request: URLRequest,
        expectedStatusCodes: Range<Int> = 200..<300
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard expectedStatusCodes.contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw TranscriptionProviderError.httpError(http.statusCode, body)
        }
        return data
    }

    private func buildTranscriptionResult(
        transcript: SonioxTranscript,
        transcription: SonioxTranscription,
        model: String
    ) -> TranscriptionResult {
        let segments = groupedSegments(from: transcript.tokens)
        let duration = transcription.audioDurationMs.map { TimeInterval($0) / 1000 }
            ?? segments.map(\.endTime).max()
            ?? 0
        return TranscriptionResult(
            text: formattedTranscript(from: transcript),
            segments: segments.isEmpty
                ? [TranscriptionSegment(startTime: 0, endTime: duration, text: transcript.text)]
                : segments,
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    private func groupedSegments(from tokens: [SonioxTranscript.Token]) -> [TranscriptionSegment] {
        guard !tokens.isEmpty else { return [] }
        guard shouldLabelSpeakers(in: tokens) else {
            return tokens.map { token in
                TranscriptionSegment(
                    startTime: TimeInterval(token.startMs) / 1000,
                    endTime: TimeInterval(token.endMs) / 1000,
                    text: token.text,
                    confidence: token.confidence
                )
            }
        }

        var grouped: [TranscriptionSegment] = []
        var currentSpeaker = tokens[0].speaker ?? ""
        var currentText = tokens[0].text
        var startMs = tokens[0].startMs
        var endMs = tokens[0].endMs
        var confidences = [tokens[0].confidence]

        for token in tokens.dropFirst() {
            let speaker = token.speaker ?? ""
            if speaker == currentSpeaker {
                currentText += token.text
                endMs = token.endMs
                confidences.append(token.confidence)
            } else {
                grouped.append(
                    labelledSegment(
                        speaker: currentSpeaker,
                        text: currentText,
                        startMs: startMs,
                        endMs: endMs,
                        confidences: confidences
                    )
                )
                currentSpeaker = speaker
                currentText = token.text
                startMs = token.startMs
                endMs = token.endMs
                confidences = [token.confidence]
            }
        }
        grouped.append(
            labelledSegment(
                speaker: currentSpeaker,
                text: currentText,
                startMs: startMs,
                endMs: endMs,
                confidences: confidences
            )
        )
        return grouped
    }

    private func labelledSegment(
        speaker: String,
        text: String,
        startMs: Int,
        endMs: Int,
        confidences: [Double]
    ) -> TranscriptionSegment {
        let prefix = speaker.isEmpty ? "" : "Speaker \(speaker): "
        return TranscriptionSegment(
            startTime: TimeInterval(startMs) / 1000,
            endTime: TimeInterval(endMs) / 1000,
            text: prefix + text,
            confidence: confidences.reduce(0, +) / Double(confidences.count)
        )
    }

    private func formattedTranscript(from transcript: SonioxTranscript) -> String {
        let segments = groupedSegments(from: transcript.tokens)
        guard shouldLabelSpeakers(in: transcript.tokens), !segments.isEmpty else {
            return transcript.text
        }
        return segments.map(\.text).joined(separator: "\n")
    }

    private func shouldLabelSpeakers(in tokens: [SonioxTranscript.Token]) -> Bool {
        Set(tokens.compactMap(\.speaker)).count > 1
    }

    private func mimeType(for url: URL) -> String {
        let mimeTypes = [
            "aac": "audio/aac",
            "aiff": "audio/aiff",
            "aif": "audio/aiff",
            "flac": "audio/flac",
            "mov": "video/quicktime",
            "mp3": "audio/mpeg",
            "mp4": "audio/mp4",
            "m4a": "audio/mp4",
            "ogg": "audio/ogg",
            "opus": "audio/opus",
            "wav": "audio/wav",
            "webm": "audio/webm"
        ]
        return mimeTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }
}

private struct SonioxFile: Decodable {
    let id: String
}

private struct SonioxCreateTranscriptionPayload: Encodable {
    let model: String
    let fileID: String
    let languageHints: [String]?
    let enableSpeakerDiarization: Bool
    let enableLanguageIdentification: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case fileID = "file_id"
        case languageHints = "language_hints"
        case enableSpeakerDiarization = "enable_speaker_diarization"
        case enableLanguageIdentification = "enable_language_identification"
    }
}

private struct SonioxTranscription: Decodable {
    let id: String
    let status: String
    let audioDurationMs: Int?
    let errorType: String?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case audioDurationMs = "audio_duration_ms"
        case errorType = "error_type"
        case errorMessage = "error_message"
    }
}

private struct SonioxTranscript: Decodable {
    struct Token: Decodable {
        let text: String
        let startMs: Int
        let endMs: Int
        let confidence: Double
        let speaker: String?
        let language: String?

        private enum CodingKeys: String, CodingKey {
            case text
            case startMs = "start_ms"
            case endMs = "end_ms"
            case confidence
            case speaker
            case language
        }
    }

    let id: String
    let text: String
    let tokens: [Token]
}

// MARK: - Live Transcriber (WebSocket client)

// swiftlint:disable type_body_length
final class SonioxLiveTranscriber: @unchecked Sendable {
    private static let websocketHost = "stt-rt.soniox.com"
    private static let websocketPath = "/transcribe-websocket"

    /// Preferred PCM chunk size: 100 ms at 16 kHz PCM16 mono.
    static let preferredChunkBytes = 3_200
    static let minimumChunkBytes = 1_600

    private let apiKey: String
    private let model: String
    private let sampleRate: Int
    private let session: URLSession
    private let logger = Logger(subsystem: "com.speak.app", category: "SonioxLiveTranscriber")
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

    init(
        apiKey: String,
        model: String = "stt-rt-v5",
        sampleRate: Int = 16000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.sampleRate = sampleRate
        self.session = session
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
        connectWebSocket()
    }

    func sendAudio(_ audioData: Data) {
        guard let task = currentWebSocketTask(), task.state == .running else { return }
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.data(audioData)) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self else { return }
            if let error {
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
                self.logger.error("Failed to send audio: \(error.localizedDescription)")
                self.currentOnError()?(error)
            }
        }
    }

    /// Soniox graceful close: send an empty binary frame to flush the final tokens.
    func signalEndOfStream() {
        guard let task = currentWebSocketTask(), task.state == .running else { return }
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.data(Data())) { _ in sendGroup.leave() }
    }

    /// Send Soniox `{"type":"finalize"}` to force any in-flight non-final tokens
    /// to be returned as final tokens. Must be called *before* `signalEndOfStream`
    /// so the server has a chance to finalize before closing.
    func sendFinalize() {
        guard let task = currentWebSocketTask(), task.state == .running else { return }
        let payload = #"{"type":"finalize"}"#
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.string(payload)) { _ in sendGroup.leave() }
    }

    func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            return webSocketTask
        }
        guard let task else { return }
        if task.state == .running {
            task.cancel(with: .normalClosure, reason: nil)
        }
        withStateLock {
            if webSocketTask === task { webSocketTask = nil }
        }
        logger.info("Soniox WebSocket connection closed")
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
        let payload: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": 1
        ]
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

    private func receiveMessages() {
        guard let task = currentWebSocketTask() else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessages()
            case .failure(let error):
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
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
                    finalizationDelegate?.sonioxDidFinishStream()
                }
            }

            if response.finished == true {
                flushFinal()
                finalizationDelegate?.sonioxDidFinishStream()
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

    private func shouldIgnoreSocketError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true }
        if nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
            return true
        }
        return false
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
