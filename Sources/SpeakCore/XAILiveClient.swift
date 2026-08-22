// The client, its event handling and the bounded finalisation exceed the
// default cap; the send bridge and outcome types already live in
// XAILiveFinalisation.swift.
// swiftlint:disable file_length
import Foundation
import os

/// Cross-platform realtime transcription client for xAI Grok Voice.
///
/// The Voice API is speech-to-speech capable, but Just Speak to It uses it in
/// transcription-only mode: manual turn detection, `grok-transcribe` input
/// captions, and no `response.create` event. That means no assistant audio is
/// generated or played.
public final class XAILiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Final shape: every transcription event restates the whole turn so far.
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript

    /// One absolute budget for the whole finalisation: pending audio sends,
    /// the commit send, the final transcript wait and close all consume the
    /// same remaining time instead of starting independent timers (#716).
    static let finishBudgetSeconds: TimeInterval = 5
    private static let pendingSendStageCapSeconds: TimeInterval = 1.5
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
    private var storedFinishOutcome: FinishOutcome?

    /// Typed outcome of the most recent `finishAndWait()`, alongside the
    /// protocol's transcript return (#716).
    var lastFinishOutcome: FinishOutcome? { withStateLock { storedFinishOutcome } }

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
        guard let task else {
            recordFinishOutcome(
                withStateLock { didReceiveFinalTranscript } ? .confirmedFinal : .bestAvailable
            )
            return currentTranscript()
        }

        // Every stage below consumes the same absolute deadline (#716): a
        // stalled pending send, a commit whose completion Foundation never
        // invokes, and a silent provider each end the finalisation within
        // `finishBudgetSeconds` in total, not per stage.
        let deadline = Date().addingTimeInterval(Self.finishBudgetSeconds)

        flushBufferedAudioForFinish(on: task)
        await waitForPendingSends(deadline: deadline)
        let commitResult = await Self.awaitBoundedSend(deadline: deadline) { completion in
            task.send(.string(#"{"type":"input_audio_buffer.commit"}"#)) { completion($0) }
        }
        switch commitResult {
        case .sent:
            break
        case .failed(let error):
            currentOnError()?(mapConnectionError(error))
            retireAfterFinish(task)
            recordFinishOutcome(.transportFailure)
            return currentTranscript()
        case .timedOut:
            // The commit was never confirmed delivered; do not wait for an
            // answer that cannot come and never claim a clean final.
            retireAfterFinish(task)
            recordFinishOutcome(.transportFailure)
            return currentTranscript()
        }

        let transcript = await waitForFinalTranscript(deadline: deadline)
        retireAfterFinish(task)
        recordFinishOutcome(
            withStateLock { didReceiveFinalTranscript } ? .confirmedFinal : .bestAvailable
        )
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

    func waitForPendingSends(deadline: Date) async {
        // The stage keeps its historical cap but can never exceed what is
        // left of the shared finalisation budget (#716).
        let timeout = min(
            Self.pendingSendStageCapSeconds,
            max(0, deadline.timeIntervalSinceNow)
        )
        let group = pendingSendGroup
        await withCheckedContinuation { continuation in
            // Lock-guarded flag instead of a captured `var`, so the closure can
            // be @Sendable for the concurrent notify/timeout callbacks below.
            let didResume = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable () -> Void = {
                let shouldResume = didResume.withLock { alreadyResumed -> Bool in
                    guard !alreadyResumed else { return false }
                    alreadyResumed = true
                    return true
                }
                guard shouldResume else { return }
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

    func waitForFinalTranscript(deadline: Date) async -> String? {
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
            let remaining = max(0, deadline.timeIntervalSinceNow)
            DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { [weak self] in
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

    /// Retires the session state a finished (or timed-out) run owns: the
    /// socket, buffered audio and the finish continuation. Guarded by task
    /// identity, so a late callback from this run cannot mutate a newer one.
    func retireAfterFinish(_ task: URLSessionWebSocketTask) {
        withStateLock {
            guard webSocketTask === task || webSocketTask == nil else { return }
            pendingAudio = []
        }
        close(task)
        resumeFinishIfNeeded(with: nil)
    }

    func recordFinishOutcome(_ outcome: FinishOutcome) {
        withStateLock { storedFinishOutcome = outcome }
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
