import Foundation

/// Cross-platform realtime transcription client for xAI Grok Voice.
///
/// The Voice API is speech-to-speech capable, but Just Speak to It uses it in
/// transcription-only mode: manual turn detection, `grok-transcribe` input
/// captions, and no `response.create` event. That means no assistant audio is
/// generated or played.
public final class XAILiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    private static let finishTimeoutSeconds: TimeInterval = 3
    private static let preconfigurationByteLimit = 24_000 * 2 * 5

    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var pendingAudio: [Data] = []
    private var isConfigured = false
    private var isStopping = false
    private var latestTranscript = ""
    private var didReceiveFinalTranscript = false
    private var finishContinuation: CheckedContinuation<String?, Never>?

    public init(
        apiKey: String,
        model: String = XAIVoiceModels.thinkFast2APIName,
        language: String? = nil,
        sampleRate: Int = 24_000,
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
            isConfigured = false
            isStopping = false
            pendingAudio = []
            latestTranscript = ""
            didReceiveFinalTranscript = false
            finishContinuation = nil
            self.onTranscript = onTranscript
            self.onError = onError
        }

        guard let url = Self.webSocketURL(model: model) else {
            onError(StreamingClientError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        withStateLock { webSocketTask = task }
        task.resume()
        receiveMessages()
        sendSessionUpdate(on: task)
    }

    public func sendAudio(_ audioData: Data) {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard isConfigured, !isStopping,
                  let task = webSocketTask, task.state == .running else {
                guard !isStopping else { return nil }
                pendingAudio.append(audioData)
                trimPendingAudio()
                return nil
            }
            return task
        }
        guard let task else { return }
        sendAudioFrame(audioData, on: task)
    }

    /// Commits the input buffer and waits (bounded) for xAI's completed
    /// transcription.
    ///
    /// Returns the session's **full** transcript, or `nil` when nothing was
    /// transcribed. xAI's transcription events are cumulative — each one
    /// carries the whole turn — so `latestTranscript` already *is* the full
    /// transcript and needs no folding (unlike the segment-shaped providers,
    /// which use `TranscriptAccumulator`).
    public func finishAndWait() async -> String? {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            return webSocketTask
        }
        guard let task else { return currentTranscript() }

        flushBufferedAudioForFinish(on: task)
        await waitForPendingSends()
        let commitError = await sendAndWait(.string(#"{"type":"input_audio_buffer.commit"}"#), on: task)
        if let commitError {
            currentOnError()?(commitError)
            close(task)
            return currentTranscript()
        }

        let transcript = await waitForFinalTranscript()
        close(task)
        return transcript
    }

    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard !isStopping else { return nil }
            isStopping = true
            return webSocketTask
        }
        if let task { close(task) }
        resumeFinishIfNeeded(with: currentTranscript())
    }

    /// Feeds one raw realtime event through the receive path. The WebSocket
    /// loop is the only production caller; tests use it to drive the client
    /// without a live socket.
    func ingest(_ text: String) {
        handleMessage(.string(text))
    }
}

// MARK: - Connection + events

private extension XAILiveClient {
    func sendSessionUpdate(on task: URLSessionWebSocketTask) {
        guard let json = Self.sessionUpdateJSON(sampleRate: sampleRate, language: language) else {
            currentOnError()?(XAILiveError.encodingFailed)
            return
        }
        send(.string(json), on: task)
    }

    func receiveMessages() {
        guard let task = currentWebSocketTask() else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                if self.currentWebSocketTask() === task {
                    self.receiveMessages()
                }
            case .failure(let error):
                if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
                self.currentOnError()?(self.mapConnectionError(error))
                self.resumeFinishIfNeeded(with: self.currentTranscript())
            }
        }
    }

    func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text else { return }

        if let transcript = Self.transcriptEvent(from: text) {
            withStateLock {
                latestTranscript = transcript.text
                if transcript.isFinal { didReceiveFinalTranscript = true }
            }
            currentOnTranscript()?(transcript.text, transcript.isFinal)
            if transcript.isFinal {
                resumeFinishIfNeeded(with: transcript.text)
            }
            return
        }

        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(XAIEnvelope.self, from: data) else {
            return
        }
        if envelope.type == "session.updated" {
            flushPendingAudio()
        } else if envelope.type == "error" {
            let error = XAILiveError.server(envelope.error?.message ?? "Unknown xAI realtime error")
            currentOnError()?(error)
            resumeFinishIfNeeded(with: currentTranscript())
        }
    }

    func flushPendingAudio() {
        let (task, frames) = withStateLock { () -> (URLSessionWebSocketTask?, [Data]) in
            isConfigured = true
            let frames = pendingAudio
            pendingAudio = []
            return (webSocketTask, frames)
        }
        guard let task, task.state == .running else { return }
        for frame in frames { sendAudioFrame(frame, on: task) }
    }
}

// MARK: - Sending + finalisation

private extension XAILiveClient {
    func sendAudioFrame(_ audioData: Data, on task: URLSessionWebSocketTask) {
        let payload = XAIInputAudioEvent(
            type: "input_audio_buffer.append",
            audio: audioData.base64EncodedString()
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            currentOnError()?(XAILiveError.encodingFailed)
            return
        }
        send(.string(json), on: task)
    }

    func send(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        let group = pendingSendGroup
        group.enter()
        task.send(message) { [weak self] error in
            defer { group.leave() }
            guard let self, let error else { return }
            if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
            self.currentOnError()?(self.mapConnectionError(error))
        }
    }

    func sendAndWait(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask
    ) async -> Error? {
        await withCheckedContinuation { continuation in
            task.send(message) { error in
                continuation.resume(returning: error)
            }
        }
    }

    func waitForPendingSends(timeout: TimeInterval = 1.5) async {
        let group = pendingSendGroup
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            let resumeOnce = {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }

            group.notify(queue: .global()) {
                resumeOnce()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeOnce()
            }
        }
    }

    func waitForFinalTranscript() async -> String? {
        await withCheckedContinuation { continuation in
            let shouldWait = withStateLock { () -> Bool in
                guard !didReceiveFinalTranscript else { return false }
                guard finishContinuation == nil else { return false }
                finishContinuation = continuation
                return true
            }
            guard shouldWait else {
                continuation.resume(returning: currentTranscript())
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.finishTimeoutSeconds) { [weak self] in
                guard let self else { return }
                self.resumeFinishIfNeeded(with: self.currentTranscript())
            }
        }
    }

    func flushBufferedAudioForFinish(on task: URLSessionWebSocketTask) {
        let frames = withStateLock { () -> [Data] in
            let frames = pendingAudio
            pendingAudio = []
            return frames
        }
        for frame in frames {
            sendAudioFrame(frame, on: task)
        }
    }

    func resumeFinishIfNeeded(with transcript: String?) {
        let continuation = withStateLock { () -> CheckedContinuation<String?, Never>? in
            let continuation = finishContinuation
            finishContinuation = nil
            return continuation
        }
        continuation?.resume(returning: transcript)
    }

    func close(_ task: URLSessionWebSocketTask) {
        let shouldClose = withStateLock { () -> Bool in
            guard webSocketTask === task else { return false }
            webSocketTask = nil
            return true
        }
        if shouldClose {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }
}

// MARK: - State + errors

private extension XAILiveClient {
    func trimPendingAudio() {
        var total = pendingAudio.reduce(0) { $0 + $1.count }
        while total > Self.preconfigurationByteLimit, !pendingAudio.isEmpty {
            total -= pendingAudio.removeFirst().count
        }
    }

    func mapConnectionError(_ error: Error) -> Error {
        let description = (error as NSError).localizedDescription.lowercased()
        if description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "xAI")
        }
        return error
    }

    func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    func currentWebSocketTask() -> URLSessionWebSocketTask? { withStateLock { webSocketTask } }
    func currentOnTranscript() -> ((String, Bool) -> Void)? { withStateLock { onTranscript } }
    func currentOnError() -> ((Error) -> Void)? { withStateLock { onError } }
    func currentTranscript() -> String? {
        withStateLock { latestTranscript.isEmpty ? nil : latestTranscript }
    }
    func isStoppingState() -> Bool { withStateLock { isStopping } }
}

public enum XAILiveError: LocalizedError {
    case encodingFailed
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the xAI realtime transcription request."
        case .server(let message):
            return "xAI realtime transcription failed: \(message)"
        }
    }
}

private struct XAIInputAudioEvent: Encodable {
    let type: String
    let audio: String
}

private struct XAIEnvelope: Decodable {
    struct ErrorPayload: Decodable {
        let message: String?
    }

    let type: String
    let error: ErrorPayload?
}
