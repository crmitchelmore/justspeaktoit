import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

// MARK: - Rev AI Live Client (portable, injected transport)

/// Shared client for Rev AI's streaming speech-to-text WebSocket. macOS and iOS
/// reach it through `LiveTranscriptionClientFactory`, Windows through
/// `DesktopLiveTranscription`.
///
/// Binary PCM frames go up; `connected`, `partial` and `final` JSON text frames
/// come back (see `RevAIStreaming`). Rev AI rejects audio before `connected`,
/// so PCM is admitted synchronously into one bounded queue from `start()` (or
/// earlier) and sent one frame at a time once that frame arrives, in capture
/// order (issue #641). A graceful finish drains every admitted frame, sends the
/// literal `EOS` and waits, inside one bounded budget, for the trailing final
/// and the server's normal closure. The transport is injected
/// (`URLSessionStreamingConnection` on Apple, WinHTTP on Windows); framing,
/// admission and lifecycle stay here so the platforms cannot drift.
///
/// State lives under one lock that is never held across a transport call, a
/// host callback, a scheduler call or a continuation resume.
public final class RevAILiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    /// Rev AI documents that a `final` hypothesis covers a section of audio
    /// whose output "will no longer change", and the next `partial` starts a
    /// fresh segment — so each final is standalone.
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    /// `EOS` makes Rev AI transcribe audio it has received but not yet
    /// finalised, so a caller must always finish gracefully.
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// The literal end-of-stream token. Rev AI closes the socket with
    /// `1007 Invalid Payload` for any other text frame — including `eos` and
    /// `Eos` — and a real WebSocket close frame loses the final hypothesis.
    static let endOfStreamToken = "EOS"

    /// Exposes the one whole-finish deadline to host lifecycle watchdogs.
    public var finalisationBudget: TimeInterval? { RevAIStreaming.finishBudget }
    /// A finish that lands before `connected` waits at most this long for it.
    static let finishReadyBudget: TimeInterval = StreamingSessionReadiness.defaultBudget
    /// `connected` must arrive within this bound of `start()`.
    static let readyDeadline: TimeInterval = 10
    /// A single send that has not completed by then means the transport stalled.
    static let sendDeadline: TimeInterval = 5
    /// How long a send that failed without a close status waits for the
    /// receive side to report the closure that explains it (a 4003 names
    /// exhausted credit where the send only saw a broken socket).
    static let sendFailureGrace: TimeInterval = 1
    /// Seconds of PCM that may be queued or in flight, including audio held
    /// until `connected`.
    static let bufferedAudioSeconds: Double = StreamingAudioPreroll.defaultBudgetSeconds
    /// Frames that may be queued or in flight, alongside the byte bound.
    static let maximumQueuedFrames = 256

    private let accessToken: String
    private let language: String?
    private let sampleRate: Int
    private let makeConnection: ConnectionFactory
    let schedule: Scheduler
    private let lock = NSLock()
    private(set) var run: RevAILiveRun

    public convenience init(
        accessToken: String,
        language: String? = nil,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.init(
            accessToken: accessToken, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        accessToken: String,
        language: String? = nil,
        sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = RevAILiveRun(sampleRate: sampleRate)
    }

    deinit { run.connection?.cancel() }

    // MARK: - StreamingTranscriptionClient

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let opening: (RevAILiveRun, URLRequest)? = withState { effects in
            let active: RevAILiveRun
            if run.phase == .idle {
                // Audio offered before the first start is already queued, in order.
                active = run
            } else {
                retire(run, &effects)
                active = RevAILiveRun(sampleRate: sampleRate)
                run = active
            }
            active.phase = .connecting
            active.delivery.onTranscript = onTranscript
            active.delivery.onError = onError
            if let failure = active.pendingFailure {
                fail(active, failure, &effects)
                return nil
            }
            guard !accessToken.isEmpty else {
                fail(active, StreamingClientError.missingAPIKey(provider: "Rev.ai"), &effects)
                return nil
            }
            guard let url = Self.webSocketURL(
                accessToken: accessToken, sampleRate: sampleRate, language: language
            ) else {
                fail(active, StreamingClientError.invalidURL, &effects)
                return nil
            }
            after(Self.readyDeadline, active, &effects) { client, active, effects in
                if !active.ready { client.fail(active, RevAILiveError.sessionNotReady, &effects) }
            }
            return (active, URLRequest(url: url))
        }
        guard let opening else { return }
        attach(makeConnection(opening.1), to: opening.0)
    }

    /// Admission is synchronous and bounded: at most `bufferedAudioSeconds` of
    /// PCM and `maximumQueuedFrames` frames may be queued or in flight,
    /// including audio held until `connected`. Exceeding either is reported
    /// (as an unready session before `connected`, a stalled transport after)
    /// instead of silently trimming the recording, and a frame of partial
    /// samples is refused before it could misalign every later sample. Audio
    /// before the first `start()` is held under the same bounds and a failure
    /// there is reported by `start()`.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        let outbound: RevAIOutbound? = withState { effects in
            let active = run
            guard active.phase == .idle || active.phase == .connecting || active.phase == .streaming,
                  active.pendingFailure == nil, active.sendFailure == nil else { return nil }
            let failure: Error?
            if !audioData.count.isMultiple(of: 2) {
                failure = RevAILiveError.invalidPCM
            } else if active.admittedFrames >= Self.maximumQueuedFrames
                || active.admittedBytes + audioData.count > active.maximumBytes {
                failure = active.ready ? stalledError : RevAILiveError.sessionNotReady
            } else {
                failure = nil
            }
            guard let failure else {
                active.outgoing.append(audioData)
                active.admittedBytes += audioData.count
                active.admittedAudio = true
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

    /// Immediate teardown; `cancel()` is the same path. A pending handshake,
    /// drain or finish is aborted at once and every waiter resumes with the
    /// text confirmed so far. Nothing is published as an error.
    public func stop() { withState { retire(run, &$0) } }

    public func cancel() { stop() }

    /// Drains every admitted frame, sends `EOS` and waits for the trailing
    /// final and the server's normal closure, all inside
    /// `RevAIStreaming.finishBudget`. Returns the whole session transcript, or
    /// `nil` when no final had words; finals that arrive during the finish are
    /// folded into it rather than also delivered through `onTranscript`. A
    /// finish that cannot reach that documented end publishes its error before
    /// returning the confirmed text, also to callers that join while the error
    /// is being delivered. Concurrent callers share one outcome; cancelling
    /// the calling task aborts the session.
    public func finishAndWait() async -> String? { await finishActiveRun() }
}

// MARK: - Run lifecycle

extension RevAILiveClient {
    var stalledError: Error { StreamingClientError.transportStalled(provider: "Rev.ai") }

    /// Runs `body` under the lock, then performs the effects it recorded.
    func withState<Value>(_ body: (inout LiveDeferredEffects) -> Value) -> Value {
        LiveDeferredEffects.applying(under: lock, body)
    }

    func isCurrent(_ active: RevAILiveRun) -> Bool { active === run && active.phase != .closed }

    /// Lifecycle events only: never the URL (it carries the access token),
    /// audio or transcript text.
    func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "RevAILiveClient").info("\(event, privacy: .public)")
        #endif
    }
}

extension RevAILiveClient: LiveRunDeadlines {
    /// Rev AI's `connected` frame, not the handshake, admits audio.
    func connectionOpened(_ active: RevAILiveRun) {
        guard withState({ _ in isCurrent(active) }) else { return }
        log("WebSocket handshake completed")
    }
}

extension RevAILiveClient: StreamingAudioReadyProviding {
    public var isReadyForAudio: Bool { lock.withLock { run.phase == .streaming && run.ready } }
}
