import Foundation
import os.log

// MARK: - Modulate Live Client (Cross-platform WebSocket)

/// Cross-platform Modulate Velma streaming speech-to-text client.
///
/// Shared by macOS and iOS. Modulate emits discrete utterance messages; this
/// client accumulates them into a running transcript and emits clean
/// `(text, isFinal)` so it can drive the generic iOS transcriber directly.
/// The first audio frame is prefixed with a streaming WAV header, as the API
/// requires. Conforms to ``StreamingTranscriptionClient``.
public final class ModulateLiveClient: StreamingTranscriptionClient, @unchecked Sendable {
    private static let endpoint = "wss://modulate-developer-apis.com/api/velma-2-stt-streaming"

    private let apiKey: String
    private let sampleRate: Int
    private let session: URLSession
    private let logger = Logger(subsystem: "com.justspeaktoit", category: "ModulateLiveClient")
    private let stateLock = NSLock()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping = false
    private var hasSentWAVHeader = false
    private var utteranceTexts: [String] = []

    public init(apiKey: String, sampleRate: Int = 16_000, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.sampleRate = sampleRate
        self.session = session
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "speaker_diarization", value: "false"),
            URLQueryItem(name: "emotion_signal", value: "false"),
            URLQueryItem(name: "accent_signal", value: "false"),
            URLQueryItem(name: "pii_phi_tagging", value: "false")
        ]
        guard let url = components.url else {
            onError(StreamingClientError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        withStateLock {
            isStopping = false
            hasSentWAVHeader = false
            utteranceTexts = []
            self.onTranscript = onTranscript
            self.onError = onError
            webSocketTask = task
        }
        task.resume()
        receiveMessages()
    }

    public func sendAudio(_ audioData: Data) {
        guard let task = currentWebSocketTask(), task.state == .running else { return }
        let prefixHeader = withStateLock { () -> Bool in
            if hasSentWAVHeader { return false }
            hasSentWAVHeader = true
            return true
        }
        var payload = prefixHeader ? Self.makeStreamingWAVHeader(sampleRate: sampleRate) : Data()
        payload.append(audioData)
        task.send(.data(payload)) { [weak self] error in
            guard let self, let error else { return }
            if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
            self.currentOnError()?(error)
        }
    }

    public func stop() {
        // Signal end-of-stream (empty text frame) so Modulate flushes, then close.
        if let task = currentWebSocketTask(), task.state == .running {
            task.send(.string("")) { _ in }
        }
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            let current = webSocketTask
            webSocketTask = nil
            return current
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - Private

    private func receiveMessages() {
        guard let task = currentWebSocketTask() else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                if self.currentWebSocketTask() != nil { self.receiveMessages() }
            case .failure(let error):
                if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
                self.currentOnError()?(error)
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let payload): text = payload
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let data = text.data(using: .utf8) else { return }

        guard let envelope = try? JSONDecoder().decode(ModulateEnvelope.self, from: data) else { return }
        switch envelope.type {
        case "utterance":
            if let message = try? JSONDecoder().decode(ModulateUtteranceMessage.self, from: data) {
                let transcript = withStateLock { () -> String in
                    utteranceTexts.append(message.utterance.text)
                    return utteranceTexts.joined(separator: " ")
                }
                currentOnTranscript()?(transcript, false)
            }
        case "done":
            let transcript = withStateLock { utteranceTexts.joined(separator: " ") }
            if !transcript.isEmpty { currentOnTranscript()?(transcript, true) }
            stop()
        case "error":
            let message = (try? JSONDecoder().decode(ModulateErrorMessage.self, from: data))?.error
            currentOnError()?(NSError(domain: "Modulate", code: 500,
                                      userInfo: [NSLocalizedDescriptionKey: message ?? "Modulate error"]))
            stop()
        default:
            break
        }
    }

    private static func makeStreamingWAVHeader(sampleRate: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(string.data(using: .ascii)!) }
        func append(_ value: UInt16) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
        }
        func append(_ value: UInt32) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
        }
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * bytesPerSample
        let blockAlign = channels * bitsPerSample / 8
        append("RIFF"); append(UInt32.max); append("WAVE"); append("fmt ")
        append(UInt32(16)); append(UInt16(1)); append(channels); append(UInt32(sampleRate))
        append(byteRate); append(blockAlign); append(bitsPerSample); append("data"); append(UInt32.max)
        return data
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

private struct ModulateEnvelope: Decodable {
    let type: String
}

private struct ModulateUtteranceMessage: Decodable {
    struct Utterance: Decodable { let text: String }
    let utterance: Utterance
}

private struct ModulateErrorMessage: Decodable {
    let error: String
}
