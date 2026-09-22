import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - Soniox Live Client (portable, injected transport)

/// Shared Soniox real-time speech-to-text client used by macOS, iOS and Windows.
///
/// One `transcribe-websocket` session per run. The configuration frame goes out
/// after the real handshake; PCM16 mono frames are admitted synchronously into a
/// bounded queue and sent one at a time behind the configuration. Soniox streams
/// token batches — `is_final` tokens are confirmed once and accumulated, and the
/// non-final tail is redisplayed on top of them, so the live transcript grows
/// monotonically. Finalisation drains the queue, sends the empty end-of-stream
/// frame (which flushes buffered audio and finalises pending tokens), and waits
/// for the `finished` response within a bounded budget. The transport is
/// injectable; framing, admission and lifecycle stay here so the platforms
/// cannot drift.
///
/// Conforms to ``FinalizingStreamingTranscriptionClient``. `finalShape` is
/// `.cumulativeTranscript`: every `onTranscript` delivery restates the whole
/// transcript so far, so finals replace rather than append.
public final class SonioxLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// The handshake must complete within this bound or the run fails visibly.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// Drain, end-of-stream and the `finished` response are bounded together.
    static let finishDeadline: TimeInterval = 8
    /// Queued frames are bounded by count as well as by the byte budget.
    static let maximumQueuedFrames = 256

    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let makeConnection: ConnectionFactory
    private let schedule: Scheduler
    private let queue = DispatchQueue(label: "SonioxLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let ownedSession: URLSession?
    private var run: SonioxLiveRun

    /// Holds audio captured before `start()` opens a run, then replays it, in
    /// capture order, ahead of the live frames once a run exists (issue #641).
    let preroll: StreamingAudioPreroll

    public convenience init(
        apiKey: String,
        model: String = "stt-rt-v5",
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) },
            ownedSession: nil
        )
    }

    public init(
        apiKey: String,
        model: String = "stt-rt-v5",
        language: String? = nil,
        sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        },
        ownedSession: URLSession? = nil
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.ownedSession = ownedSession
        self.run = SonioxLiveRun(sampleRate: sampleRate)
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        run.connection?.cancel()
        ownedSession?.invalidateAndCancel()
    }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            // Capture the pre-start audio before `close` resets the pre-roll for
            // the previous run.
            let carried = preroll.drain()
            close(run)
            let active = SonioxLiveRun(sampleRate: sampleRate)
            run = active
            active.onTranscript = onTranscript
            active.onError = onError
            guard !apiKey.isEmpty else {
                fail(StreamingClientError.missingAPIKey(provider: "Soniox"), active); return
            }
            guard sampleRate > 0 else { fail(SonioxStreamingError.invalidSampleRate(sampleRate), active); return }
            guard let config = Self.configJSON(
                apiKey: apiKey, model: model, language: language, sampleRate: sampleRate
            ), let request = Self.webSocketRequest() else {
                fail(StreamingClientError.invalidURL, active); return
            }
            active.outgoing.append(.config(config))
            // Replay audio captured before this run existed, in capture order,
            // ahead of the live frames. Best-effort: the leading buffer is
            // bounded, so an overflow here caps the replay rather than failing.
            for chunk in carried {
                if !admitAudio(chunk, into: active) { break }
            }
            active.phase = .connecting
            connect(active, request: request)
        }
    }

    /// Admission is synchronous and bounded: at most the send budget of PCM may
    /// be queued or in flight, and at most `maximumQueuedFrames` frames may wait.
    /// Exceeding either is a stalled transport, reported once — the queued audio
    /// cannot be sent, and holding the rest would only grow the failure.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            if active.phase == .idle { preroll.append(audioData); return }
            guard active.phase == .connecting || active.phase == .active else { return }
            guard audioData.count.isMultiple(of: 2) else { fail(SonioxStreamingError.invalidPCM, active); return }
            guard !active.overflowReported else { return }
            guard admitAudio(audioData, into: active) else {
                active.overflowReported = true
                fail(StreamingClientError.transportStalled(provider: "Soniox"), active)
                return
            }
            pump(active)
        }
    }

    /// Graceful finalisation: commits admitted audio, flushes with the
    /// end-of-stream frame and delivers callbacks during the short drain.
    public func stop() { synchronized { beginFinish(run, deliverCallbacks: true) } }

    /// Immediate abort. Text received so far stays available to `finishAndWait`.
    public func cancel() { synchronized { close(run) } }

    public func finishAndWait() async -> String? {
        let active = synchronized { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    guard isCurrent(active), active.connection != nil else {
                        if active === run { close(active) }
                        continuation.resume(returning: active.transcript)
                        return
                    }
                    if Task.isCancelled {
                        close(active)
                        continuation.resume(returning: active.transcript)
                        return
                    }
                    active.waiters.append(continuation)
                    beginFinish(active, deliverCallbacks: false)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    public var isConnected: Bool { synchronized { isCurrent(run) && run.didOpen && run.configSent } }

    /// Offline parse seam used by contract-style tests: folds a provider frame
    /// into the current run without a socket, exactly as the receive path does.
    func ingest(_ json: String) { synchronized { if let frame = Self.parse(json) { handle(frame, run) } } }

    // MARK: - Admission

    /// Appends one PCM frame to the run's bounded queue, or returns `false` when
    /// the frame count or send budget is already at its bound.
    private func admitAudio(_ audioData: Data, into active: SonioxLiveRun) -> Bool {
        guard active.queuedAudioFrames + (active.sending ? 1 : 0) < Self.maximumQueuedFrames,
              active.budget.admit(audioData.count) else { return false }
        active.outgoing.append(.audio(audioData))
        active.queuedAudioBytes += audioData.count
        active.queuedAudioFrames += 1
        return true
    }

    // MARK: - Connection lifecycle

    private func connect(_ active: SonioxLiveRun, request: URLRequest) {
        let connection = makeConnection(request)
        active.connection = connection
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active), !active.didOpen else { return }
                active.didOpen = true
                // Soniox has no configuration acknowledgement: the completed
                // handshake is readiness. A finishing run keeps its phase.
                if active.phase == .connecting { active.phase = .active }
                self.log("WebSocket handshake completed")
                self.pump(active)
            }
        }
        receive(active, connection)
        after(Self.readyDeadline, active) { client, active in
            if !active.didOpen { client.fail(SonioxStreamingError.connectionFailed, active) }
        }
    }

    private func receive(_ active: SonioxLiveRun, _ connection: any StreamingWebSocketConnection) {
        guard isCurrent(active) else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error):
                    // A close during finishing, after we asked to end the
                    // stream, is the expected teardown: settle with what we have.
                    if active.phase == .finishing, active.endOfStreamSent {
                        self.settleFinish(active)
                    } else if WebSocketErrorFilter.shouldIgnore(error) {
                        self.close(active)
                    } else {
                        self.fail(self.mapReceiveError(error), active)
                    }
                case .success(let message):
                    let text: String?
                    switch message {
                    case .text(let value): text = value
                    case .binary(let data): text = String(data: data, encoding: .utf8)
                    }
                    if let text, let frame = Self.parse(text) { self.handle(frame, active) }
                    self.receive(active, connection)
                }
            }
        }
    }

    // MARK: - Frame handling

    private func handle(_ frame: SonioxLiveFrame, _ active: SonioxLiveRun) {
        guard isCurrent(active) else { return }
        if let error = frame.error {
            // A provider error after we asked to close is the expected teardown;
            // settle with the best available text rather than reporting it.
            if active.phase == .finishing, active.endOfStreamSent {
                settleFinish(active)
            } else {
                fail(mapServerError(error), active)
            }
            return
        }

        active.accumulatedFinalText.append(frame.newFinalText)
        // Interims flow only while streaming. During a finish the whole
        // transcript is either returned by `finishAndWait` or delivered once as
        // a final by `settleFinish`, so nothing is doubled.
        if active.phase == .active {
            let display = active.display(nonFinalTail: frame.nonFinalText)
            if !display.isEmpty { active.onTranscript?(display, false) }
        }

        if frame.finished {
            if active.phase == .finishing {
                settleFinish(active)
            } else {
                // The server ended the stream on its own (e.g. duration limit).
                if let whole = active.transcript { active.onTranscript?(whole, true) }
                close(active)
            }
        }
    }

    // MARK: - Sending

    private enum Payload: Sendable { case config, audio(Int), endOfStream }

    /// Exactly one send is in flight. The configuration frame needs only the
    /// open socket; audio and the end-of-stream frame follow behind it.
    private func pump(_ active: SonioxLiveRun) {
        guard isCurrent(active), !active.sending, active.didOpen,
              let connection = active.connection, let next = active.outgoing.first else { return }
        let message: StreamingWebSocketMessage
        let payload: Payload
        switch next {
        case .config(let json):
            message = .text(json)
            payload = .config
        case .audio(let data):
            guard active.configSent else { return }
            message = .binary(data)
            payload = .audio(data.count)
            active.queuedAudioBytes -= data.count
            active.queuedAudioFrames -= 1
        case .endOfStream:
            guard active.configSent else { return }
            message = .binary(Data())
            payload = .endOfStream
        }
        active.outgoing.removeFirst()
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        connection.send(message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized { self.completeSend(error, payload: payload, sendID: sendID, active: active) }
        }
        after(Self.sendDeadline, active) { client, active in
            if active.sending, active.sendID == sendID { client.fail(client.stalledError, active) }
        }
    }

    private func completeSend(_ error: Error?, payload: Payload, sendID: UInt64, active: SonioxLiveRun) {
        guard isCurrent(active), active.sending, active.sendID == sendID else { return }
        active.sending = false
        if case .audio(let bytes) = payload { active.budget.release(bytes) }
        if let error {
            if active.phase == .finishing, active.endOfStreamSent { close(active) } else { fail(error, active) }
            return
        }
        switch payload {
        case .config: active.configSent = true
        case .audio: break
        case .endOfStream: active.endOfStreamSent = true
        }
        pump(active)
    }

    // MARK: - Finalisation

    /// Drains admitted PCM, then sends the empty end-of-stream frame that
    /// flushes buffered audio and finalises pending tokens. `finished`, a server
    /// close, or the finish deadline settles the run. No admitted audio still
    /// ends the stream so the server can finalise anything already sent.
    private func beginFinish(_ active: SonioxLiveRun, deliverCallbacks: Bool) {
        guard isCurrent(active), active.connection != nil else { close(active); return }
        if !deliverCallbacks { active.deliverWhileFinishing = false }
        guard active.phase != .finishing else { return }
        active.phase = .finishing
        active.deliverWhileFinishing = deliverCallbacks
        if !active.endOfStreamSent,
           !active.outgoing.contains(where: { if case .endOfStream = $0 { return true }; return false }) {
            active.outgoing.append(.endOfStream)
        }
        pump(active)
        after(Self.finishDeadline, active) { client, active in
            if active.endOfStreamSent { client.settleFinish(active) } else { client.fail(client.stalledError, active) }
        }
    }

    /// Ends a finishing run: delivers the whole transcript as a final when the
    /// graceful `stop()` asked for callbacks, then closes. `close` resolves the
    /// `finishAndWait` waiters with the same transcript.
    private func settleFinish(_ active: SonioxLiveRun) {
        guard isCurrent(active), active.phase == .finishing else { return }
        if active.deliverWhileFinishing, let whole = active.transcript {
            active.onTranscript?(whole, true)
        }
        close(active)
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "Soniox") }

    private func fail(_ error: Error, _ active: SonioxLiveRun) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript
        close(active)
        log("WebSocket session failed")
        // Publish the failure before finish returns. The run is already
        // detached, so the callback may safely start a replacement session.
        callback?(error)
        waiters.forEach { $0.resume(returning: transcript) }
    }

    private func close(_ active: SonioxLiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll()
        active.queuedAudioBytes = 0
        active.queuedAudioFrames = 0
        active.budget.reset()
        active.sending = false
        if active === run { preroll.reset() }
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript
        connection?.cancel()
        waiters.forEach { $0.resume(returning: transcript) }
        active.onTranscript = nil
        active.onError = nil
    }

    private func isCurrent(_ active: SonioxLiveRun) -> Bool { active === run && active.phase != .closed }

    private func after(_ seconds: TimeInterval, _ active: SonioxLiveRun,
                       action: @escaping @Sendable (SonioxLiveClient, SonioxLiveRun) -> Void) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    private func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }

    /// 401/403 error frames are an invalid key; everything else is a typed
    /// server error. Nothing here logs the key, transcript or audio.
    private func mapServerError(_ error: (code: Int, message: String)) -> Error {
        if error.code == 401 || error.code == 403 {
            return StreamingClientError.invalidAPIKey(provider: "Soniox")
        }
        return SonioxStreamingError.server(code: error.code, message: error.message)
    }

    private func mapReceiveError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Soniox")
        }
        return error
    }

    private func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "SonioxLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
