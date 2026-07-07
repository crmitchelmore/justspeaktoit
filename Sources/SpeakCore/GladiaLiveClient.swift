import Foundation
import os.log

// MARK: - Gladia Live Client (Cross-platform, 2-step init)

/// Cross-platform Gladia Solaria streaming speech-to-text client.
///
/// Gladia uses a two-step handshake: a POST to `/v2/live` returns a
/// single-use WebSocket URL, which this client then connects to. Audio that
/// arrives before the socket is ready is buffered. Transcript messages already
/// carry `(text, is_final)`, so they map straight onto
/// ``StreamingTranscriptionClient``. Shared by macOS and iOS.
public final class GladiaLiveClient: StreamingTranscriptionClient, @unchecked Sendable {
    private static let baseURL = URL(string: "https://api.gladia.io")!

    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let logger = Logger(subsystem: "com.justspeaktoit", category: "GladiaLiveClient")
    private let stateLock = NSLock()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping = false
    private var isConnected = false
    private var pendingAudio: [Data] = []

    public init(
        apiKey: String,
        model: String = "solaria-1",
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.session = session
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            isStopping = false
            isConnected = false
            pendingAudio = []
            self.onTranscript = onTranscript
            self.onError = onError
        }
        initiateSession()
    }

    public func sendAudio(_ audioData: Data) {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard isConnected, let task = webSocketTask, task.state == .running else {
                pendingAudio.append(audioData)
                let maxBytes = sampleRate * 2 * 5 // 5s of PCM16
                var total = pendingAudio.reduce(0) { $0 + $1.count }
                while total > maxBytes, !pendingAudio.isEmpty {
                    total -= pendingAudio.removeFirst().count
                }
                return nil
            }
            return task
        }
        guard let task else { return }
        send(audioData, on: task)
    }

    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            if let task = webSocketTask, task.state == .running {
                task.send(.string(#"{"type":"stop_recording"}"#)) { _ in }
            }
            return webSocketTask
        }
        task?.cancel(with: .normalClosure, reason: nil)
        withStateLock { webSocketTask = nil }
    }

    // MARK: - Session init (step 1)

    private func initiateSession() {
        let request: URLRequest
        do {
            request = try makeInitRequest()
        } catch {
            currentOnError()?(error)
            return
        }

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if self.isStoppingState() { return }
            if let error {
                self.currentOnError()?(error)
                return
            }
            guard let data,
                  let response = try? JSONDecoder().decode(GladiaInitResponse.self, from: data),
                  let url = URL(string: response.url) else {
                self.currentOnError()?(StreamingClientError.invalidURL)
                return
            }
            self.connectWebSocket(url: url)
        }.resume()
    }

    private func makeInitRequest() throws -> URLRequest {
        let payload = GladiaInitRequest(
            model: model,
            sampleRate: sampleRate,
            languageConfig: .from(language: language)
        )
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v2/live"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    // MARK: - WebSocket (step 2)

    private func connectWebSocket(url: URL) {
        let task = session.webSocketTask(with: url)
        let (proceed, buffered) = withStateLock { () -> (Bool, [Data]) in
            guard !isStopping else { return (false, []) }
            webSocketTask = task
            isConnected = true
            let pending = pendingAudio
            pendingAudio = []
            return (true, pending)
        }
        guard proceed else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        task.resume()
        for frame in buffered { send(frame, on: task) }
        receiveMessages()
    }

    private func send(_ audioData: Data, on task: URLSessionWebSocketTask) {
        task.send(.data(audioData)) { [weak self] error in
            guard let self, let error else { return }
            if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
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
                self.currentOnError()?(error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let payload): text = payload
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(GladiaMessage.self, from: data) else {
            return
        }
        if envelope.type == "transcript",
           let transcript = envelope.data,
           let utterance = transcript.utterance?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !utterance.isEmpty {
            currentOnTranscript()?(utterance, transcript.isFinal)
        }
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

// MARK: - Wire models

private struct GladiaInitRequest: Encodable {
    let model: String
    let encoding = "wav/pcm"
    let bitDepth = 16
    let sampleRate: Int
    let channels = 1
    let languageConfig: GladiaLanguageConfig
    let messagesConfig = GladiaMessagesConfig()

    private enum CodingKeys: String, CodingKey {
        case model, encoding, channels
        case bitDepth = "bit_depth"
        case sampleRate = "sample_rate"
        case languageConfig = "language_config"
        case messagesConfig = "messages_config"
    }
}

private struct GladiaLanguageConfig: Encodable {
    let languages: [String]
    let codeSwitching: Bool

    private enum CodingKeys: String, CodingKey {
        case languages
        case codeSwitching = "code_switching"
    }

    static func from(language: String?) -> GladiaLanguageConfig {
        guard let language,
              let code = language
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first,
              !code.isEmpty else {
            return GladiaLanguageConfig(languages: [], codeSwitching: true)
        }
        return GladiaLanguageConfig(languages: [String(code).lowercased()], codeSwitching: false)
    }
}

private struct GladiaMessagesConfig: Encodable {
    let receivePartialTranscripts = true
    let receiveFinalTranscripts = true
    let receiveErrors = true
    let receiveLifecycleEvents = true

    private enum CodingKeys: String, CodingKey {
        case receivePartialTranscripts = "receive_partial_transcripts"
        case receiveFinalTranscripts = "receive_final_transcripts"
        case receiveErrors = "receive_errors"
        case receiveLifecycleEvents = "receive_lifecycle_events"
    }
}

private struct GladiaInitResponse: Decodable {
    let id: String
    let url: String
}

private struct GladiaMessage: Decodable {
    let type: String?
    let data: GladiaTranscriptData?
}

private struct GladiaTranscriptData: Decodable {
    let isFinal: Bool
    let utterance: GladiaUtterance?

    private enum CodingKeys: String, CodingKey {
        case isFinal = "is_final"
        case utterance
    }
}

private struct GladiaUtterance: Decodable {
    let text: String?
}
