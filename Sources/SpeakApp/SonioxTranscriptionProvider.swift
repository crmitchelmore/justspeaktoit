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

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        _ = (url, apiKey, model, language)
        throw SonioxLiveError.batchNotSupported
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
        // Live-only provider; batch model list is empty intentionally.
        []
    }
}

// MARK: - Live Transcriber (WebSocket client)

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

    init(
        apiKey: String,
        model: String = "stt-rt-preview",
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

    /// Aggregates Soniox token deltas into a single transcript callback.
    /// The server may send overlapping batches of finalised + non-final tokens; we
    /// emit the union as either an interim or a final update depending on the run.
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
            guard let tokens = response.tokens, !tokens.isEmpty else { return }
            let finalText = tokens
                .filter { $0.isFinal == true }
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let interimText = tokens
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty {
                currentOnTranscript()?(finalText, true)
            } else if !interimText.isEmpty {
                currentOnTranscript()?(interimText, false)
            }
        } catch {
            logger.debug("Failed to parse Soniox response: \(error.localizedDescription)")
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
