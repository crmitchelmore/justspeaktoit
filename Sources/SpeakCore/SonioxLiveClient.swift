import Foundation
import os.log

// MARK: - Soniox Live Client (Cross-platform WebSocket)

public enum SonioxLiveError: LocalizedError {
    case invalidURLComponents
    case invalidAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidURLComponents:
            return "Failed to construct the Soniox streaming URL."
        case .invalidAPIKey:
            return "Soniox rejected the API key. Check it in Settings."
        }
    }
}

/// Cross-platform Soniox real-time speech-to-text client.
///
/// Shared by macOS and iOS. Soniox streams token batches; final tokens are
/// accumulated so the live transcript grows monotonically, and the cumulative
/// final is committed on the `finished`/finalize markers. Conforms to
/// ``StreamingTranscriptionClient``.
public final class SonioxLiveClient: StreamingTranscriptionClient, @unchecked Sendable {
    private static let websocketHost = "stt-rt.soniox.com"
    private static let websocketPath = "/transcribe-websocket"

    private let apiKey: String
    private let model: String
    private let sampleRate: Int
    private let session: URLSession
    private let logger = Logger(subsystem: "com.justspeaktoit", category: "SonioxLiveClient")
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping = false
    private var accumulatedFinalText = ""

    public init(
        apiKey: String,
        model: String = "stt-rt-v5",
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.sampleRate = sampleRate
        self.session = session
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            isStopping = false
            accumulatedFinalText = ""
            self.onTranscript = onTranscript
            self.onError = onError
        }
        connectWebSocket()
    }

    public func sendAudio(_ audioData: Data) {
        guard let task = currentWebSocketTask(), task.state == .running else { return }
        let sendGroup = pendingSendGroup
        sendGroup.enter()
        task.send(.data(audioData)) { [weak self] error in
            defer { sendGroup.leave() }
            guard let self, let error else { return }
            if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
            self.currentOnError()?(error)
        }
    }

    public func stop() {
        // Best-effort finalize: ask Soniox to commit in-flight tokens and flush
        // before closing so trailing words aren't lost.
        if let task = currentWebSocketTask(), task.state == .running {
            task.send(.string(#"{"type":"finalize"}"#)) { _ in }
            task.send(.data(Data())) { _ in }
        }
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
            guard let self, let error, !self.isStoppingState() else { return }
            self.currentOnError()?(error)
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
                self.currentOnError()?(self.mapConnectionError(error))
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) { parseResponse(text) }
        @unknown default:
            break
        }
    }

    private func parseResponse(_ json: String) {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(SonioxStreamResponse.self, from: data) else {
            return
        }

        if let code = response.errorCode {
            let message = response.errorMessage ?? "Soniox error \(code)"
            currentOnError()?(NSError(domain: "Soniox", code: code,
                                      userInfo: [NSLocalizedDescriptionKey: message]))
            return
        }

        let tokens = response.tokens ?? []
        if !tokens.isEmpty {
            var newFinals = ""
            var nonFinals = ""
            var sawFinalizationMarker = false
            for token in tokens {
                // `<fin>` acknowledges a manual finalize; `<end>` marks session end.
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

            if sawFinalizationMarker { flushFinal() }
        }

        if response.finished == true { flushFinal() }
    }

    private func flushFinal() {
        let text: String? = withStateLock {
            let snapshot = accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
            return snapshot.isEmpty ? nil : snapshot
        }
        if let text { currentOnTranscript()?(text, true) }
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

    private func currentWebSocketTask() -> URLSessionWebSocketTask? { withStateLock { webSocketTask } }
    private func isStoppingState() -> Bool { withStateLock { isStopping } }
    private func currentOnTranscript() -> ((String, Bool) -> Void)? { withStateLock { onTranscript } }
    private func currentOnError() -> ((Error) -> Void)? { withStateLock { onError } }
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

private struct SonioxToken: Decodable {
    let text: String
    let isFinal: Bool?

    private enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}
