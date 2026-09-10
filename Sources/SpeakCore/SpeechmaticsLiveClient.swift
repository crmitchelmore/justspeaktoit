// The client owns connection, the RecognitionStarted gate, the sequence
// accounting and bounded finalisation; the constants, errors and frame
// decoding live in SpeechmaticsRealtime.swift.
// swiftlint:disable file_length
import Foundation

/// Cross-platform realtime client for the Speechmatics `v2` WebSocket API.
///
/// `StartRecognition` opens the session, `AddAudio` binary frames carry PCM16,
/// `AddPartialTranscript` and `AddTranscript` come back, and `EndOfStream`
/// commits the tail before `EndOfTranscript` closes it. Speechmatics rejects
/// audio before `RecognitionStarted`, so leading capture is held in
/// `StreamingAudioPreroll` and replayed on that frame (issue #641).
///
/// Contract: https://docs.speechmatics.com/rt-api-ref (read 2026-09-10).
public final class SpeechmaticsLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable { // swiftlint:disable:this type_body_length line_length
    /// `AddTranscript` finalises a new span of audio that is never restated,
    /// so each one is its own segment.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `EndOfStream` commits audio Speechmatics has received but not yet
    /// transcribed, so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true

    private static let sendDrainBudget: TimeInterval = 1

    private let apiKey: String
    private let accuracyModel: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let stateLock = NSLock()
    private let finishLock = NSLock()
    private let pendingSends = DispatchGroup()
    private let logger = SpeakLogger.logger(category: "SpeechmaticsLiveClient")

    private var webSocketTask: URLSessionWebSocketTask?
    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isReady = false
    private var isStopping = false
    private var isFinishing = false
    private var sentAudioFrameCount = 0
    private var lastAcknowledgedSeqNo = -1
    private var accumulated = TranscriptAccumulator(shape: .standaloneSegments)
    private var finishContinuation: CheckedContinuation<String?, Never>?

    let preroll: StreamingAudioPreroll

    public init(
        apiKey: String,
        model: String = SpeechmaticsRealtime.defaultModel,
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accuracyModel = SpeechmaticsRealtime.accuracyModel(from: model)
        self.language = language
        self.sampleRate = sampleRate
        self.session = session
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
    }

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard !apiKey.isEmpty else {
            onError(StreamingClientError.missingAPIKey(provider: "Speechmatics"))
            return
        }
        beginSession(onTranscript: onTranscript, onError: onError)
        connect()
    }

    /// Arms the callbacks and clears per-recording state without opening a
    /// socket. `start` is this plus `connect()`; tests pair it with `ingest`.
    func beginSession(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        withStateLock {
            self.onTranscript = onTranscript
            self.onError = onError
            isReady = false
            isStopping = false
            isFinishing = false
            sentAudioFrameCount = 0
            lastAcknowledgedSeqNo = -1
            accumulated.reset()
            finishContinuation = nil
        }
        preroll.reset()
    }

    /// Feeds one raw server frame through the receive path. The WebSocket loop
    /// is the only production caller; tests drive the client with it.
    func ingest(_ text: String) {
        handle(.string(text))
    }

    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            guard isReady, !isStopping, !isFinishing,
                  let task = webSocketTask, task.state == .running else { return nil }
            return task
        }
        guard let task else {
            // Speechmatics rejects audio before `RecognitionStarted`, so the
            // user's opening words are held rather than dropped.
            if !isEnding { preroll.append(audioData) }
            return
        }
        send(audioData, on: task)
    }

    public func finishAndWait() async -> String? {
        let (task, wasReady) = withStateLock { () -> (URLSessionWebSocketTask?, Bool) in
            isFinishing = true
            return (webSocketTask, isReady)
        }
        // Without `RecognitionStarted` there is no server-side session to
        // commit: `EndOfStream` would be rejected, so close instead of waiting.
        guard let task, wasReady else {
            stop()
            return fullTranscript()
        }
        let result = await awaitFinalTranscript { [weak self, weak task] in
            DispatchQueue.global().async { [weak self, weak task] in
                guard let self, let task else { return }
                self.flushPreroll(to: task)
                _ = self.pendingSends.wait(timeout: .now() + Self.sendDrainBudget)
                self.sendEndOfStream(on: task)
            }
        }
        stop()
        return result
    }

    /// The bounded wait for `EndOfTranscript`, resolved by that frame (the
    /// common case) or by the finish budget.
    ///
    /// `whenArmed` runs once the waiter is installed, so the `EndOfStream`
    /// frame cannot race its own completion handler; tests use it to deliver
    /// frames into an armed finish without a socket.
    func awaitFinalTranscript(
        budget: TimeInterval = SpeechmaticsRealtime.finishBudget,
        whenArmed: () -> Void = {}
    ) async -> String? {
        await withCheckedContinuation { continuation in
            finishLock.lock()
            finishContinuation = continuation
            finishLock.unlock()

            whenArmed()

            DispatchQueue.global().asyncAfter(deadline: .now() + budget) { [weak self] in
                self?.resolveFinish()
            }
        }
    }

    public func stop() {
        let task = withStateLock { () -> URLSessionWebSocketTask? in
            isStopping = true
            isReady = false
            let task = webSocketTask
            webSocketTask = nil
            return task
        }
        preroll.reset()
        task?.cancel(with: .normalClosure, reason: nil)
        resolveFinish()
    }

    // MARK: - Protocol frames

    /// The `StartRecognition` frame. `enable_partials` is what produces the
    /// interim captions; `max_delay` is the documented latency/accuracy dial.
    static func startRecognitionPayload(
        language: String?,
        accuracyModel: String,
        sampleRate: Int,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> String? {
        let payload: [String: Any] = [
            "message": "StartRecognition",
            "audio_format": [
                "type": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": sampleRate
            ],
            "transcription_config": [
                "language": SpeechmaticsRealtime.languageCode(
                    for: language, systemLocaleIdentifier: systemLocaleIdentifier
                ),
                "model": accuracyModel,
                "max_delay": 0.7,
                "enable_partials": true
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// `EndOfStream.last_seq_no` is the number of `AddAudio` frames sent. The
    /// server's own `AudioAdded` acknowledgements are taken as a floor so a
    /// send that completed out of order cannot under-report the tail.
    static func endOfStreamLastSequenceNumber(lastAcknowledged: Int, sentFrameCount: Int) -> Int {
        max(lastAcknowledged, sentFrameCount, 0)
    }

    /// Speechmatics rejects an `AddAudio` frame below its minimum size, so the
    /// trailing partial chunk is zero-padded rather than dropped — otherwise
    /// the last words of a recording never reach the service (issues #849, #949).
    static func paddedFinalChunk(_ chunk: Data) -> Data {
        guard chunk.count < SpeechmaticsRealtime.minimumChunkBytes else { return chunk }
        var padded = chunk
        padded.append(
            contentsOf: repeatElement(UInt8(0), count: SpeechmaticsRealtime.minimumChunkBytes - chunk.count)
        )
        return padded
    }

    // MARK: - Connection

    static func webSocketURL() -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = SpeechmaticsRealtime.webSocketHost
        components.path = SpeechmaticsRealtime.webSocketPath
        return components.url
    }

    private func connect() {
        guard let url = Self.webSocketURL() else {
            currentOnError()?(StreamingClientError.invalidURL)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        let published = withStateLock { () -> Bool in
            guard !isStopping, !isFinishing else { return false }
            isReady = false
            webSocketTask = task
            return true
        }
        guard published else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        task.resume()
        sendStartRecognition(on: task)
        receiveMessages(on: task)
    }

    private func sendStartRecognition(on task: URLSessionWebSocketTask) {
        guard let payload = Self.startRecognitionPayload(
            language: language, accuracyModel: accuracyModel, sampleRate: sampleRate
        ) else {
            currentOnError()?(StreamingClientError.invalidURL)
            return
        }
        pendingSends.enter()
        task.send(.string(payload)) { [weak self] error in
            guard let self else { return }
            self.pendingSends.leave()
            if let error, !self.isEnding, !WebSocketErrorFilter.shouldIgnore(error) {
                self.handleTransportFailure(error)
            }
        }
    }

    private func sendEndOfStream(on task: URLSessionWebSocketTask) {
        let lastSeqNo = withStateLock {
            Self.endOfStreamLastSequenceNumber(
                lastAcknowledged: self.lastAcknowledgedSeqNo,
                sentFrameCount: self.sentAudioFrameCount
            )
        }
        let payload: [String: Any] = ["message": "EndOfStream", "last_seq_no": lastSeqNo]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            resolveFinish()
            return
        }
        task.send(.string(json)) { [weak self] error in
            guard let self, let error, !WebSocketErrorFilter.shouldIgnore(error) else { return }
            self.logger.error("Speechmatics EndOfStream send failed: \(error.localizedDescription)")
            self.resolveFinish()
        }
    }

    private func receiveMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, self.isCurrent(task) else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                if self.isCurrent(task) { self.receiveMessages(on: task) }
            case .failure(let error):
                self.handleTransportFailure(error)
            }
        }
    }

    /// Only an explicit `Error` frame ends the session. An unrecognised frame —
    /// `Info`, `Warning`, or a field added upstream — decodes to `nil` and is
    /// ignored, matching every other shared client, because it must never end a
    /// live recording.
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard let event = SpeechmaticsRealtimeEvent(message: message) else { return }

        switch event {
        case .recognitionStarted:
            withStateLock { isReady = true }
            if let task = currentTask() { flushPreroll(to: task) }
        case .audioAdded(let seqNo):
            withStateLock { lastAcknowledgedSeqNo = max(lastAcknowledgedSeqNo, seqNo) }
        case .partial(let text):
            currentOnTranscript()?(text, false)
        case .final(let text):
            withStateLock { accumulated.append(final: text) }
            currentOnTranscript()?(text, true)
        case .endOfTranscript:
            resolveFinish()
        case .failure(let error):
            fail(error)
        }
    }

    private func handleTransportFailure(_ error: Error) {
        if isEnding || WebSocketErrorFilter.shouldIgnore(error) {
            resolveFinish()
            return
        }
        fail(mapConnectionError(error))
    }

    private func fail(_ error: Error) {
        let callback = withStateLock { () -> ((Error) -> Void)? in
            guard !isStopping else { return nil }
            isStopping = true
            isReady = false
            let callback = onError
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            return callback
        }
        callback?(error)
        resolveFinish()
    }

    private func send(_ audio: Data, on task: URLSessionWebSocketTask) {
        withStateLock { sentAudioFrameCount += 1 }
        pendingSends.enter()
        task.send(.data(audio)) { [weak self] error in
            guard let self else { return }
            self.pendingSends.leave()
            if let error, !self.isEnding, !WebSocketErrorFilter.shouldIgnore(error) {
                self.handleTransportFailure(error)
            }
        }
    }

    /// Replays held audio in capture order. The last chunk is padded to the
    /// service's minimum frame size so a short tail is still transcribed.
    private func flushPreroll(to task: URLSessionWebSocketTask) {
        let held = preroll.drain()
        guard let last = held.last else { return }
        for chunk in held.dropLast() { send(chunk, on: task) }
        send(Self.paddedFinalChunk(last), on: task)
    }

    @discardableResult
    private func resolveFinish() -> Bool {
        finishLock.lock()
        let continuation = finishContinuation
        finishContinuation = nil
        finishLock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: fullTranscript())
        return true
    }

    private func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("not authorised")
            || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Speechmatics")
        }
        return error
    }

    /// Whether `RecognitionStarted` has arrived and the socket accepts audio.
    var isSessionReady: Bool { withStateLock { isReady } }
    var audioFrameCount: Int { withStateLock { sentAudioFrameCount } }

    private var isEnding: Bool { withStateLock { isStopping || isFinishing } }
    private func isCurrent(_ task: URLSessionWebSocketTask) -> Bool {
        withStateLock { webSocketTask === task }
    }
    private func currentTask() -> URLSessionWebSocketTask? { withStateLock { webSocketTask } }
    private func currentOnTranscript() -> ((String, Bool) -> Void)? { withStateLock { onTranscript } }
    private func currentOnError() -> ((Error) -> Void)? { withStateLock { onError } }
    private func fullTranscript() -> String? { withStateLock { accumulated.transcriptOrNil } }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
