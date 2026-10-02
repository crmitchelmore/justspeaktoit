import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - ElevenLabs Live Client (portable, injected transport)

/// Shared ElevenLabs Scribe v2 realtime client used by macOS, iOS and Windows.
///
/// One `/v1/speech-to-text/realtime` socket per run, with the server's VAD
/// committing segments while recording. Audio is sent as base64
/// `input_audio_chunk` frames, one at a time and only after the server's
/// `session_started` frame; until then the newest five seconds wait in the
/// pre-roll. Every committed segment, from the VAD or from the finish, counts
/// once: a timestamped twin never adds it a second time. A finish drains the
/// admitted audio, sends one manual commit and reads the finals that follow for
/// a bounded post-commit window, because VAD commits carry no correlation id
/// that could mark the commit's own answer. The transport is injectable;
/// framing, admission and lifecycle stay here so the platforms cannot drift.
public final class ElevenLabsLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Each `committed_transcript` is a newly finalised segment, so finals append.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// Handshake plus `session_started` must land within this bound.
    public static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    public static let sendDeadline: TimeInterval = 5
    /// A finish that lands before readiness waits at most this long for it.
    public static let finishReadyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// The post-commit window: how long a finish reads finals once its manual
    /// commit is sent.
    public static let finishBudget: TimeInterval = 1.5
    /// Bounds the whole finish, which returns what it has by then: the wait
    /// for readiness, the drain of admitted audio (one send deadline), then the
    /// commit's send and its post-commit window (one finish budget each).
    public static let finishDrainBudget = finishReadyBudget + sendDeadline + 2 * finishBudget
    /// Exposes the active client's bound to platform lifecycle watchdogs.
    public var finalisationBudget: TimeInterval? { timing.overall }
    /// Queued frames are bounded by count as well as by the five-second byte budget.
    public static let maximumQueuedFrames = 256

    private let apiKey: String
    private let modelID: String
    private let language: String?
    /// PCM16 rate the caller streams in; it is declared to the endpoint and used
    /// to size the send budget and pre-roll.
    let sampleRate: Int
    private let makeConnection: ConnectionFactory
    private let schedule: Scheduler
    /// Readiness, commit and finish bounds; the documented statics in production.
    let timing: Timing
    private let queue = DispatchQueue(label: "ElevenLabsLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var run: ElevenLabsLiveRun
    /// Holds audio captured before `start()` opens a run (issue #641) and, as
    /// the established Mac transcriber did, the newest five seconds captured
    /// before `session_started`; both are replayed in capture order once the
    /// session starts.
    let preroll: StreamingAudioPreroll

    public convenience init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
        language: String? = nil,
        sampleRate: Int = LiveTranscriptionProviderID.elevenlabs.expectedSampleRate,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, modelID: modelID, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public convenience init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
        language: String? = nil,
        sampleRate: Int = LiveTranscriptionProviderID.elevenlabs.expectedSampleRate,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.init(
            apiKey: apiKey, modelID: modelID, language: language, sampleRate: sampleRate,
            timing: .production, makeConnection: makeConnection, schedule: schedule
        )
    }

    init(
        apiKey: String,
        modelID: String,
        language: String?,
        sampleRate: Int,
        timing: Timing,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler
    ) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.language = language
        self.sampleRate = sampleRate
        self.timing = timing
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = ElevenLabsLiveRun(sampleRate: sampleRate)
        let budgetRate = ElevenLabsLiveProtocol.supportedSampleRates.contains(sampleRate)
            ? sampleRate : LiveTranscriptionProviderID.elevenlabs.expectedSampleRate
        self.preroll = StreamingAudioPreroll(sampleRate: budgetRate)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            let opening = run.phase == .idle ? preroll.drain() : []
            close(run)
            let active = ElevenLabsLiveRun(sampleRate: sampleRate)
            run = active
            active.onTranscript = onTranscript
            active.onError = onError
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { fail(ElevenLabsLiveError.missingAPIKey, active); return }
            guard ElevenLabsLiveProtocol.supportedSampleRates.contains(sampleRate) else {
                fail(ElevenLabsStreamingError.invalidSampleRate(sampleRate), active)
                return
            }
            guard let url = ElevenLabsLiveProtocol.webSocketURL(
                modelID: modelID, language: language, sampleRate: sampleRate
            ) else {
                fail(ElevenLabsLiveError.invalidURL, active)
                return
            }
            var request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            let connection = makeConnection(request)
            active.connection = connection
            active.phase = .connecting
            connection.resume { [weak self, weak active] in
                guard let self, let active else { return }
                // ElevenLabs sends no client hello: audio waits for the server's
                // `session_started`, so the open handshake is only logged here.
                self.synchronized { if self.isCurrent(active) { self.log("WebSocket handshake completed") } }
            }
            receive(active)
            // A finish has its own, shorter readiness bound.
            after(timing.startup, active) { client, active in
                if !active.ready, active.phase != .finishing {
                    client.fail(ElevenLabsLiveError.connectionFailed, active)
                }
            }
            // Audio offered before this first run waits for `session_started`,
            // ahead of anything captured later.
            opening.forEach(preroll.append)
        }
    }

    /// Audio captured before `session_started` waits in the pre-roll, which
    /// keeps the newest five seconds. Once the session has started, admission is
    /// synchronous and bounded: at most five seconds of PCM may be queued or in
    /// flight and at most `maximumQueuedFrames` frames may wait. Exceeding
    /// either is a transport stall, reported once, rather than silently grown.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            switch active.phase {
            case .idle:
                preroll.append(audioData)
            case .connecting, .active:
                guard active.ready else { preroll.append(audioData); return }
                enqueueAudio(audioData, active)
            case .finishing, .closed:
                return
            }
        }
    }

    /// Float32 samples converted to Int16 PCM, routed through ``sendAudio(_:)``.
    public func sendAudioSamples(_ samples: UnsafePointer<Float>, frameCount: Int) {
        sendAudio(PCM16Converter.data(from: samples, frameCount: frameCount))
    }

    /// The finish's manual commit flushes audio the server's VAD has not yet
    /// committed. Shared consumers must always allow that finalisation path.
    public var finishFlushesBufferedAudio: Bool { true }

    /// Drains the admitted audio, sends one manual commit and reads the finals
    /// that follow for the post-commit window, all inside `finishDrainBudget`.
    /// Returns the session's full transcript, or `nil` when nothing was
    /// transcribed; finals consumed here are not also delivered through
    /// `onTranscript`. A finish that reaches a bound returns what it has.
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
                    beginFinish(active)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    /// Immediate abort; text received so far stays available to `finishAndWait`.
    public func stop() { synchronized { close(run) } }
    public func cancel() { synchronized { close(run) } }

    public var isConnected: Bool { synchronized { isCurrent(run) && run.ready } }

    /// Same receive parser the socket loop uses, exposed so contract tests can
    /// drive the client without a live transport.
    func parseTranscriptResponse(_ json: String) { synchronized { parse(json, run) } }

}

extension ElevenLabsLiveClient {

    var stalledError: Error { StreamingClientError.transportStalled(provider: "ElevenLabs") }

    private func receive(_ active: ElevenLabsLiveRun) {
        guard isCurrent(active), let connection = active.connection else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error):
                    // A spurious ENOTCONN re-arms the receive; one that
                    // persists is a stalled transport.
                    guard !WebSocketErrorFilter.isSpuriousDisconnect(error) else {
                        if !self.rearmReceive(active) { self.fail(self.stalledError, active) }
                        return
                    }
                    self.fail(error, active)
                case .success(let message):
                    active.ignoredReceiveFailures.reset()
                    switch message {
                    case .text(let text): self.parse(text, active)
                    case .binary(let data):
                        if let text = String(data: data, encoding: .utf8) { self.parse(text, active) }
                    }
                    self.receive(active)
                }
            }
        }
    }

    private func rearmReceive(_ active: ElevenLabsLiveRun) -> Bool {
        guard active.ignoredReceiveFailures.allowsRetry() else { return false }
        after(IgnoredReceiveFailureWindow.retryDelay, active) { client, active in client.receive(active) }
        return true
    }

    private func parse(_ json: String, _ active: ElevenLabsLiveRun) {
        guard active === run, active.phase != .closed else { return }
        guard let event = ElevenLabsRealtimeEvent.parse(json) else { return }
        switch event {
        case .sessionStarted:
            markReady(active)
        case .partialTranscript(let text):
            guard active.phase != .finishing, !text.isEmpty else { return }
            active.onTranscript?(text, false)
        case .committedTranscript(let text):
            handleCommitted(text, timestamped: false, active)
        case .committedTranscriptWithTimestamps(let text):
            handleCommitted(text, timestamped: true, active)
        case .authError:
            fail(StreamingClientError.invalidAPIKey(provider: "ElevenLabs"), active)
        case .serverError(let type, let message):
            fail(ElevenLabsStreamingError.serverError(type: type, message: message), active)
        case .warning, .ignored:
            break
        }
    }

    /// Releases the audio held for the handshake, in capture order, and the
    /// commit of a finish that was waiting for it.
    private func markReady(_ active: ElevenLabsLiveRun) {
        // The offline parser seam has no session for the pre-roll to join.
        guard !active.ready, active.phase != .idle else { return }
        active.ready = true
        if active.phase == .connecting { active.phase = .active }
        log("Session started")
        for audio in preroll.drain() {
            // Nothing was admitted before readiness, and the pre-roll holds at
            // most the same five seconds as the send budget.
            guard active.sendBudget.admit(audio.count) else { fail(stalledError, active); return }
            active.outgoing.append(.audio(audio))
        }
        if active.phase == .finishing { queueCommit(active) }
        pump(active)
    }

    /// Every committed segment counts once, from the VAD while recording or
    /// from the finish's commit: no commit carries a correlation id. A
    /// timestamped twin repeats the segment it pairs with and never adds it
    /// again; either form arriving alone still counts.
    private func handleCommitted(_ text: String, timestamped: Bool, _ active: ElevenLabsLiveRun) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !active.finalTwins.isTwin(timestamped: timestamped) else { return }
        active.accumulated.append(final: text)
        // A segment that lands during the finish is returned by it instead.
        if active.phase != .finishing { active.onTranscript?(text, true) }
    }

    func fail(_ error: Error, _ active: ElevenLabsLiveRun) {
        guard active === run, active.phase != .closed else { return }
        let onError = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.transcript
        close(active)
        log("Session failed")
        // Publish the failure before finish returns. The closed run owns these
        // waiters even when the callback starts a replacement session.
        onError?(error)
        waiters.forEach { $0.resume(returning: transcript) }
    }

    func close(_ active: ElevenLabsLiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll(keepingCapacity: false)
        active.sendBudget.reset()
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

    func isCurrent(_ active: ElevenLabsLiveRun) -> Bool { active === run && active.phase != .closed }

    func after(
        _ seconds: TimeInterval, _ active: ElevenLabsLiveRun,
        action: @escaping @Sendable (ElevenLabsLiveClient, ElevenLabsLiveRun) -> Void
    ) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }

    private func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "ElevenLabsLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
