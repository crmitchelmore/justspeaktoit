import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - Gemini Live Client (portable, injected transport)

/// Cross-platform Google Gemini 3.5 Transcribe Live streaming client. macOS
/// and iOS reach it through `LiveTranscriptionClientFactory`, Windows through
/// `DesktopLiveTranscription`.
///
/// Speaks the Gemini Live API's `BidiGenerateContent` WebSocket in
/// transcription-only mode (see `GeminiLiveProtocol`): `responseModalities:
/// ["TEXT"]`, server-side voice activity detection, and no model response is
/// ever requested, so no assistant audio or text is generated or billed.
///
/// One run owns the socket. `setup` is its first frame. PCM16 mono audio is
/// admitted synchronously into a bounded queue, waits for `setupComplete`, and
/// goes up base64-encoded one frame at a time. A graceful finish drains every
/// admitted frame, sends `audioStreamEnd` and completes, inside one bounded
/// budget, when the server answers it: the first turn end (an
/// `inputTranscription` or `turnComplete`) after `audioStreamEnd` was handed
/// over, once no utterance remains open; or, when nothing was left to
/// transcribe, a short quiet period after that frame is delivered. A `goAway`
/// (the documented ten-minute session limit) flushes the current socket the
/// same way and continues the recording, in order, on a new one.
///
/// The transport is injected (`URLSessionStreamingConnection` on Apple, WinHTTP
/// on Windows); framing, admission and lifecycle stay here so the platforms
/// cannot drift. State lives under one lock that is never held across a
/// transport call, a host callback, a scheduler call or a continuation resume.
/// Never logs audio, transcript text or the API key.
public final class GeminiLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Final shape: each `inputTranscription` carries one finalised utterance,
    /// so finals append rather than replace (issue #700).
    public let finalShape: TranscriptFinalShape = .standaloneSegments

    /// `audioStreamEnd` genuinely flushes audio the server has received but not
    /// yet transcribed, so a stop must always drain.
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// One deadline bounds a graceful finish: any wait for the setup, the drain
    /// of admitted audio, `audioStreamEnd` and the server's answer. A healthy
    /// finish ends on that answer; nothing sleeps.
    public static let finishBudget: TimeInterval = 8
    /// Exposes `finishBudget` to host lifecycle watchdogs.
    public var finalisationBudget: TimeInterval? { Self.finishBudget }
    /// A finish that lands before the setup completes waits at most this long for it.
    static let finishReadyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// A socket must complete its setup within this bound of being requested.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// After `audioStreamEnd` is delivered with no utterance in flight, how
    /// long the server has to finalise audio it had not reported yet before
    /// the stream is taken as complete. The Live API acknowledges the end of
    /// a stream with nothing but that final, and sends none for silence.
    static let trailingSettle: TimeInterval = 1.5
    /// Seconds of PCM that may be queued or in flight, including audio held
    /// while a session sets up or hands over.
    static let bufferedAudioSeconds: Double = StreamingAudioPreroll.defaultBudgetSeconds
    /// Frames that may be queued or in flight, alongside the byte bound.
    static let maximumQueuedFrames = 256

    private let apiKey: String
    private let model: String
    private let language: String?
    /// Keyword biasing forwarded by `LiveTranscriptionClientFactory`; internal
    /// so tests can assert the forwarding rather than infer it.
    let customVocabulary: [String]
    private let mode: GeminiTranscriptionMode
    let sampleRate: Int
    private let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let lock = NSLock()
    private(set) var run: GeminiLiveRun

    public convenience init(
        apiKey: String,
        model: String = GeminiTranscribeModels.liveAPIName,
        language: String? = nil,
        customVocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, customVocabulary: customVocabulary, mode: mode,
            sampleRate: sampleRate, makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String,
        model: String = GeminiTranscribeModels.liveAPIName,
        language: String? = nil,
        customVocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim,
        sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.language = language
        self.customVocabulary = customVocabulary
        self.mode = mode
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = GeminiLiveRun(sampleRate: sampleRate)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let opening: (GeminiLiveRun, URLRequest)? = withState { effects in
            let active: GeminiLiveRun
            if run.phase == .idle {
                // Audio offered before the first start is already queued, in order.
                active = run
            } else {
                retire(run, &effects)
                active = GeminiLiveRun(sampleRate: sampleRate)
                run = active
            }
            active.phase = .connecting
            active.onTranscript = onTranscript
            active.onError = onError
            if let failure = active.pendingFailure {
                fail(active, failure, &effects)
                return nil
            }
            guard let request = GeminiLiveProtocol.webSocketRequest(apiKey: apiKey) else {
                fail(active, StreamingClientError.missingAPIKey(provider: GeminiLiveProtocol.provider), &effects)
                return nil
            }
            guard let setup = Self.setupMessageJSON(
                model: model, language: language, customVocabulary: customVocabulary, mode: mode
            ) else {
                fail(active, GeminiLiveError.encodingFailed, &effects)
                return nil
            }
            active.request = request
            active.setupMessage = setup
            active.socketGeneration += 1
            armReadyDeadline(active, &effects)
            return (active, request)
        }
        guard let opening else { return }
        connect(opening.0, request: opening.1)
    }

    /// Admission is synchronous and bounded: at most `bufferedAudioSeconds` of
    /// PCM and `maximumQueuedFrames` frames may be queued or in flight,
    /// including audio held while a session sets up or hands over. Exceeding
    /// either is reported as a stalled transport instead of silently trimming
    /// the recording, and a frame of partial samples is refused before it could
    /// misalign every later sample. Audio before the first `start()` is held
    /// under the same bounds and a failure there is reported by `start()`.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        let outbound: GeminiOutbound? = withState { effects in
            let active = run
            guard active.phase == .idle || active.phase == .connecting || active.phase == .streaming,
                  active.pendingFailure == nil else { return nil }
            let failure: Error?
            if !audioData.count.isMultiple(of: 2) {
                failure = GeminiLiveStreamingError.invalidPCM
            } else if active.admittedFrames >= Self.maximumQueuedFrames
                || active.admittedBytes + audioData.count > active.maximumBytes {
                failure = stalledError
            } else {
                failure = nil
            }
            guard let failure else {
                active.outgoing.append(audioData)
                active.admittedBytes += audioData.count
                return claim(active, &effects)
            }
            if active.phase == .idle {
                // No callbacks exist yet. The held audio can no longer be sent
                // intact, so it is released now and `start()` reports why.
                active.pendingFailure = failure
                active.outgoing.removeAll()
                active.admittedBytes = 0
            } else {
                fail(active, failure, &effects)
            }
            return nil
        }
        if let outbound { drive(outbound) }
    }

    /// Immediate teardown; `cancel()` is the same path. A pending setup, drain
    /// or finish is aborted at once and every waiter resumes with the text
    /// confirmed so far. Cancellation is not a provider failure.
    public func stop() { withState { retire(run, &$0) } }

    public func cancel() { stop() }

    /// Drains every admitted frame, sends `audioStreamEnd` and waits for the
    /// server's answer, all inside `finishBudget`. Returns the whole session
    /// transcript, or `nil` when no utterance produced words; finals that
    /// arrive during the finish are folded into it rather than also delivered
    /// through `onTranscript`, so a caller that appends never doubles them. A
    /// finish that cannot reach that answer publishes its error before
    /// returning the confirmed text, also to callers that join while the error
    /// is being delivered. Concurrent callers share one outcome; cancelling the
    /// calling task aborts the session.
    public func finishAndWait() async -> String? {
        let active: GeminiLiveRun = withState { _ in run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                withState { effects in join(active, continuation, &effects) }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.withState { effects in if self.isCurrent(active) { self.retire(active, &effects) } }
        }
    }

    // MARK: - Session

    private func join(
        _ active: GeminiLiveRun, _ continuation: CheckedContinuation<String?, Never>,
        _ effects: inout GeminiLiveEffects
    ) {
        let transcript = active.transcript
        switch active.phase {
        case .connecting, .streaming, .finishing:
            guard !Task.isCancelled else {
                retire(active, &effects)
                effects.add { continuation.resume(returning: transcript) }
                return
            }
            active.waiters.append(continuation)
            beginFinish(active, &effects)
        case .idle:
            // Never started, so nothing was sent and nothing can be finished.
            retire(active, &effects)
            effects.add { continuation.resume(returning: transcript) }
        case .closed:
            // A failure still being published keeps late callers until its
            // error is out, exactly like callers that were already waiting.
            guard !active.deliveringFailure else {
                active.lateWaiters.append(continuation)
                return
            }
            effects.add { continuation.resume(returning: transcript) }
        }
    }

    /// The connection is built and resumed outside the lock: the factory and
    /// the transport may call back synchronously.
    func connect(_ active: GeminiLiveRun, request: URLRequest) {
        let connection = makeConnection(request)
        let attached: Bool = withState { _ in
            guard isCurrent(active), active.connection == nil else { return false }
            active.connection = connection
            return true
        }
        guard attached else {
            connection.cancel()
            return
        }
        log("WebSocket connecting (model=\(model))")
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.markOpened(active, connection)
        }
        receive(active, connection)
    }

    /// The handshake completed: the setup frame goes first.
    private func markOpened(_ active: GeminiLiveRun, _ connection: any StreamingWebSocketConnection) {
        let outbound: GeminiOutbound? = withState { effects in
            guard isCurrent(active), active.connection === connection, !active.opened else { return nil }
            active.opened = true
            if active.phase == .connecting { active.phase = .streaming }
            log("WebSocket handshake completed")
            return claim(active, &effects)
        }
        if let outbound { drive(outbound) }
    }
}

// MARK: - Run lifecycle

extension GeminiLiveClient {
    var stalledError: Error { StreamingClientError.transportStalled(provider: GeminiLiveProtocol.provider) }

    /// Finish callers waiting on the active run, including those held while a
    /// failure is delivered; lets tests observe that a finish has registered
    /// without sleeping.
    var pendingFinishes: Int { withState { _ in run.waiters.count + run.lateWaiters.count } }

    /// Runs `body` under the lock, then performs the effects it recorded.
    func withState<Value>(_ body: (inout GeminiLiveEffects) -> Value) -> Value {
        var effects = GeminiLiveEffects()
        let value = lock.withLock { body(&effects) }
        effects.perform()
        return value
    }

    func isCurrent(_ active: GeminiLiveRun) -> Bool { active === run && active.phase != .closed }

    /// The current socket must answer its setup within `readyDeadline`. The
    /// deadline belongs to that socket, so one that replaced it is unaffected.
    func armReadyDeadline(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        let socket = active.socketGeneration
        after(Self.readyDeadline, active, &effects) { client, active, effects in
            guard active.socketGeneration == socket, !active.ready else { return }
            client.fail(active, GeminiLiveStreamingError.sessionNotReady, &effects)
        }
    }

    /// Why a bounded wait for the server ended without its answer.
    func expiredError(_ active: GeminiLiveRun) -> Error {
        if !active.ready { return GeminiLiveStreamingError.sessionNotReady }
        if active.openUtterance != nil { return GeminiLiveStreamingError.incompleteUtterance }
        return stalledError
    }

    /// Retires the run at once, then, outside the lock, publishes the failure
    /// before any finish caller of this run returns: those already waiting and
    /// those that join while it is being delivered. Transcripts already on their
    /// way to the host arrive first: the report waits for them and is released
    /// by the last one to return, on its thread, so no caller blocks on a host
    /// callback. Words a finish had withheld follow, so the host's visible draft
    /// keeps everything the server sent, while finish callers receive confirmed
    /// text only. A callback that starts a new session cannot be touched by
    /// this cleanup: the run is detached, and only its own callers are released.
    func fail(_ active: GeminiLiveRun, _ error: Error, _ effects: inout GeminiLiveEffects) {
        guard isCurrent(active) else { return }
        let onTranscript = active.onTranscript
        let onError = active.onError
        let finals = active.withheldFinals
        let draft = active.withheldDraft
        let waiters = active.waiters
        let transcript = active.transcript
        active.waiters.removeAll()
        active.deliveringFailure = true
        retire(active, &effects)
        log("Session failed")
        let report = {
            if let onTranscript {
                finals.forEach { onTranscript($0, true) }
                if let draft { onTranscript(draft, false) }
            }
            onError?(error)
            waiters.forEach { $0.resume(returning: transcript) }
            self.withState { effects in self.endFailureDelivery(active, &effects) }
        }
        if active.transcriptsInFlight > 0 {
            active.deferredFailureReport = report
        } else {
            effects.add(report)
        }
    }

    /// A transcript callback returned. The last one out releases a failure
    /// report that was waiting behind it, on this thread and outside the lock.
    func transcriptReturned(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        active.transcriptsInFlight -= 1
        guard active.transcriptsInFlight == 0, let report = active.deferredFailureReport else { return }
        active.deferredFailureReport = nil
        effects.add(report)
    }

    /// The error is out: callers that joined while it was being delivered return.
    private func endFailureDelivery(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        active.deliveringFailure = false
        let late = active.lateWaiters
        let transcript = active.transcript
        active.lateWaiters.removeAll()
        effects.add { late.forEach { $0.resume(returning: transcript) } }
    }

    /// Ends the run for good: its socket is cancelled, admitted audio and its
    /// budget are released, callbacks are dropped and every waiter resumes with
    /// the confirmed transcript.
    func retire(_ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        let waiters = active.waiters
        let transcript = active.transcript
        active.connection = nil
        active.outgoing.removeAll()
        active.admittedBytes = 0
        active.inFlightAudioBytes = 0
        active.sending = false
        active.waiters.removeAll()
        active.withheldFinals.removeAll()
        active.withheldDraft = nil
        active.onTranscript = nil
        active.onError = nil
        effects.add {
            connection?.cancel()
            waiters.forEach { $0.resume(returning: transcript) }
        }
    }

    /// Arms a deadline owned by `active`. It acts only while that run is still
    /// current, so a late timer cannot touch a stopped or replacement run.
    func after(
        _ seconds: TimeInterval, _ active: GeminiLiveRun, _ effects: inout GeminiLiveEffects,
        action: @escaping @Sendable (GeminiLiveClient, GeminiLiveRun, inout GeminiLiveEffects) -> Void
    ) {
        let schedule = self.schedule
        effects.add {
            schedule(seconds) { [weak self, weak active] in
                guard let self, let active else { return }
                self.withState { effects in
                    if self.isCurrent(active) { action(self, active, &effects) }
                }
            }
        }
    }

    /// Lifecycle events only: never a key, audio or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "GeminiLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
