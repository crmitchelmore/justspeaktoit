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
/// One `/v1/speech-to-text/realtime` socket per run. Audio is admitted
/// synchronously into a bounded queue and sent one base64 `input_audio_chunk`
/// at a time, but only after the server's `session_started` frame. Finalisation
/// owns manual segments of at most twenty seconds, waits for each commit before
/// sending the next segment, and drains admitted audio on finish. A commit
/// requires its `committed_transcript` within a bounded budget. The transport is injectable; framing, admission and
/// lifecycle stay here so the platforms cannot drift.
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
    /// How long a finish waits, after the manual commit, for the trailing final.
    public static let finishBudget: TimeInterval = 1.5
    /// Stay below the provider's approximately 36-second automatic commit.
    static let segmentSeconds = 20
    /// Bounds readiness, all queued sends and both a pending and trailing commit.
    public static let finishDrainBudget = finishReadyBudget + sendDeadline + 2 * finishBudget
    /// Exposes the active client's bound to platform lifecycle watchdogs.
    public var finalisationBudget: TimeInterval? { Self.finishDrainBudget }
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
    private let queue = DispatchQueue(label: "ElevenLabsLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var run: ElevenLabsLiveRun
    /// Holds audio captured before `start()` opens a run (issue #641); a started
    /// session parks connecting audio in its own bounded send queue instead.
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

    public init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
        language: String? = nil,
        sampleRate: Int = LiveTranscriptionProviderID.elevenlabs.expectedSampleRate,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.language = language
        self.sampleRate = sampleRate
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
            after(Self.readyDeadline, active) { client, active in
                if !active.ready { client.fail(ElevenLabsLiveError.connectionFailed, active) }
            }
            for audio in opening {
                guard isCurrent(active) else { break }
                sendAudio(audio)
            }
        }
    }

    /// Admission is synchronous and bounded: at most five seconds of PCM may be
    /// queued or in flight and at most `maximumQueuedFrames` frames may wait.
    /// Exceeding either is a transport stall, reported once, rather than silently
    /// grown or dropped. Audio captured before `start()` is parked in the pre-roll.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            if active.phase == .idle { preroll.append(audioData); return }
            guard active.phase == .connecting || active.phase == .active else { return }
            guard audioData.count.isMultiple(of: 2) else {
                fail(ElevenLabsStreamingError.invalidPCM, active)
                return
            }
            guard active.outgoing.count + (active.sending ? 1 : 0) < Self.maximumQueuedFrames,
                  active.sendBudget.admit(audioData.count) else {
                fail(stalledError, active)
                return
            }
            active.outgoing.append(audioData)
            pump(active)
        }
    }

    /// Float32 samples converted to Int16 PCM, routed through ``sendAudio(_:)``.
    public func sendAudioSamples(_ samples: UnsafePointer<Float>, frameCount: Int) {
        sendAudio(PCM16Converter.data(from: samples, frameCount: frameCount))
    }

    /// Manual commit flushes audio that the provider may not yet have exposed
    /// as text. Shared consumers must always allow that finalisation path.
    public var finishFlushesBufferedAudio: Bool { true }

    /// Graceful stop waits for any current commit, drains admitted audio, then
    /// commits a nonempty remainder and awaits its `committed_transcript`.
    /// Returns the session's full transcript, or `nil` when nothing was
    /// transcribed; a trailing final consumed here is not also delivered through
    /// `onTranscript`.
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
                    guard active.phase != .finishing else { return }
                    active.phase = .finishing
                    if active.outgoing.isEmpty, active.segmentBytes == 0, !active.sending {
                        close(active)
                        return
                    }
                    after(Self.finishDrainBudget, active) { client, active in
                        client.fail(ElevenLabsStreamingError.missingCompletion, active)
                    }
                    if active.ready {
                        pump(active)
                    } else {
                        // Stop before `session_started`: keep the admitted audio
                        // and bound the wait for readiness so a finish can't hang.
                        after(Self.finishReadyBudget, active) { client, active in
                            if !active.ready { client.fail(ElevenLabsStreamingError.sessionNotReady, active) }
                        }
                    }
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
                    self.fail(error, active)
                case .success(let message):
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
            handleCommitted(text, active)
        case .authError:
            fail(StreamingClientError.invalidAPIKey(provider: "ElevenLabs"), active)
        case .serverError(let type, let message):
            fail(ElevenLabsStreamingError.serverError(type: type, message: message), active)
        case .warning:
            break
        case .ignored:
            break
        }
    }

    private func markReady(_ active: ElevenLabsLiveRun) {
        guard !active.ready else { return }
        active.ready = true
        if active.phase == .connecting { active.phase = .active }
        log("Session started")
        pump(active)
    }

    private func handleCommitted(_ text: String, _ active: ElevenLabsLiveRun) {
        // The offline parser seam preserves existing transcript tests. A
        // live socket, however, must only finalise its one owned commit.
        if active.phase == .idle {
            if !text.isEmpty { active.accumulated.append(final: text) }
            return
        }
        guard active.pendingCommit != nil, !active.commitFinalReceived else {
            fail(ElevenLabsStreamingError.unexpectedCompletion, active)
            return
        }
        active.commitFinalReceived = true
        if !text.isEmpty { active.accumulated.append(final: text) }
        if active.phase != .finishing, !text.isEmpty { active.onTranscript?(text, true) }
        pump(active)
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

// MARK: - Error Types

/// Legacy ElevenLabs connection errors. Retained with the same cases and
/// descriptions the app and its tests already depend on; streaming-specific
/// failures use ``ElevenLabsStreamingError`` and the shared ``StreamingClientError``.
public enum ElevenLabsLiveError: LocalizedError {
    case invalidURL
    case connectionFailed
    case sendFailed
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct ElevenLabs WebSocket URL"
        case .connectionFailed:
            return "Failed to establish WebSocket connection to ElevenLabs"
        case .sendFailed:
            return "Failed to send audio data to ElevenLabs"
        case .missingAPIKey:
            return "ElevenLabs API key is missing. Please configure it in Settings."
        }
    }
}
