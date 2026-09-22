import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

/// Cross-platform realtime client for the Speechmatics `v2` WebSocket API.
///
/// `StartRecognition` opens the session, `AddAudio` binary frames carry PCM16,
/// `AddPartialTranscript` and `AddTranscript` come back, and `EndOfStream`
/// commits the tail before `EndOfTranscript` closes it. Speechmatics rejects
/// audio before `RecognitionStarted`, so leading capture is queued and drained
/// only once that frame arrives (issue #641).
///
/// The transport is injected through `StreamingWebSocketConnection`: Apple
/// platforms reuse the caller's `URLSession`, and Windows supplies its native
/// WinHTTP socket. Provider framing, bounded PCM admission, send ordering,
/// restart identity and finalisation stay here so the platforms cannot drift.
///
/// Contract: https://docs.speechmatics.com/api-ref/realtime-transcription-websocket
/// (read 2026-09-22).
public final class SpeechmaticsLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// `AddTranscript` finalises a new span of audio that is never restated,
    /// so each one is its own segment.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `EndOfStream` commits audio Speechmatics has received but not yet
    /// transcribed, so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true

    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// A single `AddAudio` or control send that has not completed by then means
    /// the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// How long a finish waits for `RecognitionStarted` before giving up on the
    /// held capture and closing with the best available transcript.
    static let finishReadyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// How long a finish waits for `EndOfTranscript` after `EndOfStream`.
    static let finishBudget: TimeInterval = SpeechmaticsRealtime.finishBudget
    /// A backstop on queued frames; the five-second byte budget is the tighter
    /// bound in practice because every frame is at least `minimumChunkBytes`.
    static let maximumQueuedFrames = 256

    let apiKey: String
    let accuracyModel: String
    let language: String?
    let sampleRate: Int
    let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let queue = DispatchQueue(label: "SpeechmaticsLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    var run: SpeechmaticsLiveRun

    /// Retains the existing pre-start priming contract. Capture handed over
    /// before a session starts is parked here; once a session is connecting,
    /// its bounded send queue holds the audio instead.
    let preroll: StreamingAudioPreroll

    public convenience init(
        apiKey: String,
        model: String = SpeechmaticsRealtime.defaultModel,
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String,
        model: String = SpeechmaticsRealtime.defaultModel,
        language: String? = nil,
        sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accuracyModel = SpeechmaticsRealtime.accuracyModel(from: model)
        self.language = language
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        self.run = SpeechmaticsLiveRun(sampleRate: sampleRate)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        synchronized {
            let active = arm(onTranscript: onTranscript, onError: onError)
            guard !apiKey.isEmpty else {
                fail(StreamingClientError.missingAPIKey(provider: "Speechmatics"), active)
                return
            }
            connect(active)
        }
    }

    /// Speechmatics rejects an `AddAudio` frame below its minimum size, and it
    /// rejects any audio before `RecognitionStarted`, so capture is coalesced
    /// into legal frames and queued until the session is both open and ready.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            if active.phase == .idle {
                // Before a session starts there is no queue to admit into; the
                // bounded preroll holds the opening capture (issue #641).
                preroll.append(audioData)
                return
            }
            guard active.phase == .connecting || active.phase == .active else { return }
            guard active.outgoing.count + (active.sending ? 1 : 0) < Self.maximumQueuedFrames else {
                fail(stalledError, active)
                return
            }
            // Admit the whole chunk before any framing so an oversized chunk is
            // rejected before the queue grows. Coalescing conserves bytes, so
            // the net admitted amount is exactly the chunk it accepted.
            guard active.budget.admit(audioData.count) else {
                fail(stalledError, active)
                return
            }
            let (frames, remainder) = Self.outboundFrames(appending: audioData, to: active.outboundBuffer)
            active.outboundBuffer = remainder
            for frame in frames { active.outgoing.append(.audio(frame)) }
            pump(active)
        }
    }

    /// Immediate abort. Text received so far stays available to `finishAndWait`.
    public func stop() { synchronized { close(run) } }

    public func finishAndWait() async -> String? {
        let active = synchronized { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    // No live socket: `EndOfStream` would be rejected, so close
                    // rather than burning the budget, and hand back what was
                    // transcribed.
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
                    active.finishWaiters.append(continuation)
                    beginFinish(active)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    // MARK: - Socket-free test helpers

    /// Arms the callbacks and clears per-recording state without opening a
    /// socket. `start` is this plus `connect`; tests pair it with `ingest`.
    func beginSession(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        synchronized { _ = arm(onTranscript: onTranscript, onError: onError) }
    }

    /// Feeds one raw server frame through the receive path. The transport's
    /// receive loop is the only production caller; tests drive the client with it.
    func ingest(_ text: String) {
        synchronized { parse(.text(text), run) }
    }

    /// The bounded wait for `EndOfTranscript`, resolved by that frame (the
    /// common case) or by the budget. `whenArmed` runs once the waiter is
    /// installed, so tests can deliver frames into an armed finish without a
    /// socket, exactly as the production `EndOfStream` completion does.
    func awaitFinalTranscript(
        budget: TimeInterval = SpeechmaticsRealtime.finishBudget,
        whenArmed: () -> Void = {}
    ) async -> String? {
        let active = synchronized { run }
        return await withCheckedContinuation { continuation in
            synchronized {
                guard active.phase != .closed else {
                    continuation.resume(returning: active.transcript)
                    return
                }
                active.finishWaiters.append(continuation)
            }
            whenArmed()
            after(budget, active) { client, active in client.resolveFinishWaiters(active) }
        }
    }

    // MARK: - Run lifecycle

    private func arm(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) -> SpeechmaticsLiveRun {
        close(run)
        let active = SpeechmaticsLiveRun(sampleRate: sampleRate)
        run = active
        active.onTranscript = onTranscript
        active.onError = onError
        return active
    }

    func fail(_ error: Error, _ active: SpeechmaticsLiveRun) {
        guard isCurrent(active) else { return }
        let callback = active.onError
        let waiters = active.finishWaiters
        active.finishWaiters.removeAll()
        let transcript = active.transcript
        close(active)
        log("Speechmatics session failed")
        // Publish the failure before finish returns. The run is already
        // detached, so the callback may start a replacement session safely.
        callback?(error)
        waiters.forEach { $0.resume(returning: transcript) }
    }

    func close(_ active: SpeechmaticsLiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll()
        active.outboundBuffer.removeAll(keepingCapacity: false)
        active.budget.reset()
        active.sending = false
        if active === run { preroll.reset() }
        let waiters = active.finishWaiters
        active.finishWaiters.removeAll()
        let transcript = active.transcript
        connection?.cancel()
        waiters.forEach { $0.resume(returning: transcript) }
        active.onTranscript = nil
        active.onError = nil
    }

    /// Resolves every pending finish waiter with the run's best available
    /// transcript, leaving the run otherwise intact (used by the finish budget).
    func resolveFinishWaiters(_ active: SpeechmaticsLiveRun) {
        let waiters = active.finishWaiters
        active.finishWaiters.removeAll()
        let transcript = active.transcript
        waiters.forEach { $0.resume(returning: transcript) }
    }

    var stalledError: Error { StreamingClientError.transportStalled(provider: "Speechmatics") }

    func isCurrent(_ active: SpeechmaticsLiveRun) -> Bool { active === run && active.phase != .closed }

    var isSessionReady: Bool { synchronized { isCurrent(run) && run.ready } }
    var audioFrameCount: Int { synchronized { run.sentAudioFrameCount } }

    func after(_ seconds: TimeInterval, _ active: SpeechmaticsLiveRun,
               action: @escaping @Sendable (SpeechmaticsLiveClient, SpeechmaticsLiveRun) -> Void) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    @discardableResult
    func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }

    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "SpeechmaticsLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}

// MARK: - Protocol frames

extension SpeechmaticsLiveClient {
    static func webSocketURL() -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = SpeechmaticsRealtime.webSocketHost
        components.path = SpeechmaticsRealtime.webSocketPath
        return components.url
    }

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

    static func endOfStreamPayload(lastSeqNo: Int) -> String? {
        let payload: [String: Any] = ["message": "EndOfStream", "last_seq_no": lastSeqNo]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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

    /// Splits a running buffer into frames Speechmatics will accept.
    ///
    /// The shared capture path converts one 4,096-frame tap buffer at a time,
    /// which at a 44.1 kHz or 48 kHz input rate becomes well under 3,200 bytes
    /// of 16 kHz PCM — under the service's minimum, so *every* ordinary frame
    /// was being rejected, not just the tail. Chunks are therefore accumulated
    /// and emitted only once they reach the minimum, in capture order; what is
    /// left over stays buffered for the next chunk, and the terminal remainder
    /// is padded and sent by `flushOutboundTail`.
    ///
    /// - Returns: The frames to send now, and the remainder to keep.
    static func outboundFrames(appending chunk: Data, to buffer: Data) -> (frames: [Data], remainder: Data) {
        var pending = buffer
        pending.append(chunk)
        guard pending.count >= SpeechmaticsRealtime.minimumChunkBytes else {
            return ([], pending)
        }
        // One frame per flush keeps the send count — and so `last_seq_no` —
        // proportional to the audio, and every frame is at or above the
        // minimum by construction.
        return ([pending], Data())
    }
}
