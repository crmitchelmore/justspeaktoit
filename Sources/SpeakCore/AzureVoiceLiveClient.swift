import Foundation

/// Azure Voice Live is used only for input transcription. No response.create
/// is sent, and VAD response generation is explicitly disabled.
public final class AzureVoiceLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    // The public protocol accepts ordinary closures; this box transfers their
    // ownership to the serial state queue, where callbacks are always invoked.
    private struct Callbacks: @unchecked Sendable {
        let transcript: (String, Bool) -> Void
        let error: (Error) -> Void
    }
    private let queue = DispatchQueue(label: "AzureVoiceLiveClient")
    private let credentials: String
    private let endpoint: String
    private let model: String
    private let language: String?
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var configured = false
    private var finishing = false
    private var buffer: [Data] = []
    private var bufferedBytes = 0
    private var outgoing: [URLSessionWebSocketTask.Message] = []
    private var sending = false
    private var audioSinceCommit = false
    private var commitAcknowledged = false
    private var commitSent = false
    private var awaitingFinishConfiguration = false
    private var items: [String] = []
    private var transcripts: [String: String] = [:]
    private var completed: Set<String> = []
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var finishContinuation: CheckedContinuation<String?, Never>?

    public init(
        credentials: String,
        endpoint: String,
        model: String,
        language: String?,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.session = session
    }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let callbacks = Callbacks(transcript: onTranscript, error: onError)
        queue.async { [self] in
            guard socket == nil else { return }
            self.onTranscript = callbacks.transcript
            self.onError = callbacks.error
            configured = false
            finishing = false
            commitAcknowledged = false
            commitSent = false
            awaitingFinishConfiguration = false
            audioSinceCommit = false
            buffer = []; bufferedBytes = 0; outgoing = []; sending = false
            items = []; transcripts = [:]; completed = []
            do {
                let request = try Self.connectionRequest(credentials: credentials, endpoint: endpoint)
                let socket = session.webSocketTask(with: request)
                self.socket = socket
                socket.resume()
                receive(socket)
                enqueue(try Self.sessionUpdate(model: model, language: language))
                queue.asyncAfter(deadline: .now() + 10) { [weak self, weak socket] in
                    guard let self, let socket, self.socket === socket, !self.configured else { return }
                    self.fail(AzureSpeechError.timedOut)
                }
            } catch { fail(error) }
        }
    }

    public func sendAudio(_ audioData: Data) {
        queue.async { [self] in
            guard socket != nil, !finishing, !audioData.isEmpty else { return }
            if !configured {
                guard bufferedBytes + audioData.count <= 24_000 * 2 * 5 else {
                    fail(AzureSpeechError
                        .configuration("Azure did not become ready before the audio buffer filled."))
                    return
                }
                buffer.append(audioData); bufferedBytes += audioData.count
            } else { appendAudio(audioData) }
        }
    }

    public func finishAndWait() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !finishing, socket != nil else { continuation.resume(returning: transcript); return }
                finishing = true
                finishContinuation = continuation
                let activeSocket = socket
                if configured { beginFinish() }
                // One deadline covers startup, queued sends, commit and finals.
                queue.asyncAfter(deadline: .now() + 5) { [weak self, weak activeSocket] in
                    guard let self, let activeSocket, self.socket === activeSocket else { return }
                    if self.finishContinuation != nil { self.onError?(AzureSpeechError.timedOut) }
                    self.close()
                }
            }
        }
    }

    public func stop() {
        queue.async { [self] in close() }
    }

    /// Drives the same event parser in contract tests without a network session.
    func ingest(_ json: String) {
        queue.sync { handle(Data(json.utf8)) }
    }

    private var transcript: String? {
        let text = items.compactMap { transcripts[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func appendAudio(_ data: Data) {
        audioSinceCommit = true
        enqueue("{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(data.base64EncodedString())\"}")
    }

    private func beginFinish() {
        // Voice Live rejects disabling VAD after a session starts. Commit queued
        // audio without changing VAD, then use a harmless configuration update
        // as a server acknowledgement barrier behind the commit.
        awaitingFinishConfiguration = true
        commit()
        enqueue(Self.finalizationBarrier)
    }

    private func commit() {
        if audioSinceCommit {
            commitAcknowledged = false
            enqueue(#"{"type":"input_audio_buffer.commit"}"#)
        } else {
            commitAcknowledged = true
            finishIfComplete()
        }
    }

    private func enqueue(_ json: String) {
        guard outgoing.count < 250 else {
            fail(AzureSpeechError.configuration("Azure could not keep up with the audio stream."))
            return
        }
        outgoing.append(.string(json))
        sendNext()
    }

    private func sendNext() {
        guard !sending, !outgoing.isEmpty, let socket else { return }
        sending = true
        let message = outgoing.removeFirst()
        if case .string(let json) = message, json == #"{"type":"input_audio_buffer.commit"}"# {
            commitSent = true
        }
        socket.send(message) { [weak self, weak socket] error in
            guard let self, let socket else { return }
            self.queue.async {
                guard self.socket === socket else { return }
                self.sending = false
                if let error { self.fail(error) } else { self.sendNext() }
            }
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            self.queue.async {
                guard self.socket === socket else { return }
                switch result {
                case .failure(let error): self.fail(error)
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: self.fail(AzureSpeechError.invalidResponse); return
                    }
                    self.handle(data)
                    if self.socket === socket { self.receive(socket) }
                }
            }
        }
    }

    // The switch mirrors Azure event types; keep the contract in one place.
    // swiftlint:disable:next cyclomatic_complexity
    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { fail(AzureSpeechError.invalidResponse); return }
        switch type {
        case "session.updated":
            configured = true
            let pending = buffer; buffer = []; bufferedBytes = 0
            pending.forEach(appendAudio)
            if finishing {
                if awaitingFinishConfiguration {
                    awaitingFinishConfiguration = false
                    finishIfComplete()
                } else { beginFinish() }
            }
        case "input_audio_buffer.committed":
            if let id = object["item_id"] as? String, !items.contains(id) { items.append(id) }
            // Only acknowledge after all audio/commit writes have left our queue.
            if finishing && commitSent { commitAcknowledged = true }

            finishIfComplete()
        case "conversation.item.input_audio_transcription.delta":
            update(object, final: false)
        case "conversation.item.input_audio_transcription.completed":
            update(object, final: true)
        case "conversation.item.input_audio_transcription.failed":
            fail(AzureSpeechError.invalidResponse)
        case "error":
            let error = object["error"] as? [String: Any]
            if finishing, error?["code"] as? String == "input_audio_buffer_commit_empty" {
                commitAcknowledged = true
                finishIfComplete()
            } else {
                // Do not surface raw envelopes which may echo request details.
                fail(AzureSpeechError.configuration(
                    "Azure Voice Live rejected the session. Check model access and resource region."
                ))
            }
        default: break
        }
    }

    private func update(_ object: [String: Any], final: Bool) {
        guard let id = object["item_id"] as? String, !completed.contains(id) else { return }
        if !items.contains(id) { items.append(id) }
        if final {
            transcripts[id] = object["transcript"] as? String ?? ""
            completed.insert(id)
        } else if let delta = object["delta"] as? String { transcripts[id, default: ""] += delta }
        if !finishing, let transcript { onTranscript?(transcript, final) }
        finishIfComplete()
    }

    private func finishIfComplete() {
        guard finishing, !awaitingFinishConfiguration, commitAcknowledged,
              items.allSatisfy(completed.contains) else { return }
        close()
    }

    private func fail(_ error: Error) {
        onError?(error)
        close()
    }

    private func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil; buffer = []; bufferedBytes = 0; outgoing = []; sending = false
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(returning: transcript)
        onTranscript = nil; onError = nil
    }
}

extension AzureVoiceLiveClient {
    static let finalizationBarrier = #"{"type":"session.update","session":{"modalities":["text"]}}"#

    static func connectionRequest(credentials: String, endpoint: String) throws -> URLRequest {
        let config = try AzureSpeechConfiguration(credentials: credentials)
        let origin = try AzureSpeechConfiguration.resourceURL(endpoint)
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.path = "/voice-live/realtime"
        components.queryItems = [
            .init(name: "api-version", value: "2026-04-10"),
            .init(name: "model", value: "gpt-4.1")
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        return request
    }

    static func sessionUpdate(model: String, language: String?) throws -> String {
        guard ["azure-speech", "mai-transcribe"].contains(model)
        else { throw AzureSpeechError.unsupportedModel }
        var transcription: [String: Any] = ["model": model]
        if let language, !language.isEmpty, !["auto", "automatic"].contains(language) {
            transcription["language"] = language.replacingOccurrences(of: "_", with: "-")
        }
        let event: [String: Any] = ["type": "session.update", "session": [
            "modalities": ["text"], "input_audio_format": "pcm16", "input_audio_sampling_rate": 24_000,
            "input_audio_transcription": transcription,
            "turn_detection": [
                "type": "azure_semantic_vad",
                "create_response": false,
                "silence_duration_ms": 500
            ]
        ] as [String: Any]]
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let json = String(data: data, encoding: .utf8) else { throw AzureSpeechError.invalidResponse }
        return json
    }

}
