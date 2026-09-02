import Foundation

// MARK: - Streaming provider warm-up policy (issue #663)

/// How far a live-transcription provider's connection may be warmed before the
/// user presses the hotkey.
///
/// Two levels are possible in principle:
///
/// * **Endpoint probe** — resolve DNS and complete a credential-free HTTPS
///   request against the provider's host. This warms resolver state and may
///   make a TLS session ticket available, but it does not claim to pre-connect
///   the WebSocket or populate a different `URLSession`'s connection pool.
/// * **Pre-connect** — open the WebSocket and send the provider's config frame
///   before the hotkey, holding the session open until it is needed.
///
/// A probe is only enabled when the live client uses `URLSession.shared`.
/// AssemblyAI and OpenAI construct dedicated sessions, so probing through the
/// shared session would not prove transport reuse and is deliberately disabled.
/// No provider is fully pre-connected: the first frame on the socket *is* the
/// session. Soniox, Speechmatics, ElevenLabs, Cartesia, Gladia, Modulate,
/// OpenAI Realtime and xAI all require an authenticated config/`StartRecognition`
/// frame immediately after the upgrade, which creates a server-side session;
/// AssemblyAI's Universal-Streaming meters *session duration* rather than audio
/// duration, so an idle warm socket bills the user for silence; and Deepgram
/// closes a connection that receives no audio within roughly ten seconds
/// (`NET-0001`), which would turn a warm socket into a reconnect storm. Holding
/// a configured socket open on the chance the user might dictate is therefore
/// either billable, rate-limited, or unstable depending on the provider — so
/// the app does not do it for any of them.
///
/// ``preconnect`` is deliberately absent from this enum rather than present and
/// unused: adding it is the right change on the day a provider documents a free
/// idle handshake, and until then a case no provider returns would be untested
/// machinery.
public enum LiveStreamWarmUp: Equatable, Sendable {
    /// Nothing to warm: the provider runs on-device.
    case unsupported
    /// Probe this host without credentials or a provider session.
    case endpointProbe(host: String)

    /// The host to warm, when there is one.
    public var host: String? {
        switch self {
        case .unsupported:
            return nil
        case .endpointProbe(let host):
            return host
        }
    }
}

extension LiveTranscriptionProviderID {
    /// The host the provider's streaming socket connects to, or `nil` for
    /// on-device providers. Kept beside the clients that own these URLs; a test
    /// asserts every cloud provider declares one.
    public var streamingHost: String? {
        switch self {
        case .apple:
            return nil
        case .deepgram:
            return "api.deepgram.com"
        case .cartesia:
            return "api.cartesia.ai"
        case .gladia:
            return "api.gladia.io"
        case .google:
            return GeminiTranscribeModels.apiHost
        case .modulate:
            return "modulate-developer-apis.com"
        case .assemblyai:
            // The app prefers the EU endpoint and falls back to global; warming
            // the preferred one is what matters for the common path.
            return "streaming.eu.assemblyai.com"
        case .soniox:
            return "stt-rt.soniox.com"
        case .elevenlabs:
            return "api.elevenlabs.io"
        case .openai:
            return "api.openai.com"
        case .speechmatics:
            return "eu.rt.speechmatics.com"
        case .xai:
            return "api.x.ai"
        case .meta:
            return "api.meta.ai"
        }
    }

    /// How far this provider's connection may be warmed ahead of a session.
    public var streamWarmUp: LiveStreamWarmUp {
        switch self {
        case .apple, .assemblyai, .openai:
            return .unsupported
        case .deepgram, .cartesia, .gladia, .google, .modulate, .soniox, .elevenlabs,
             .speechmatics, .xai, .meta:
            guard let host = self.streamingHost else { return .unsupported }
            return .endpointProbe(host: host)
        }
    }
}

// MARK: - Warm tracker

/// Tracks which streaming host has a recent endpoint probe and when it expires.
///
/// Pure logic so the freshness and re-warm rules are testable without touching
/// the network. The owner asks ``hostNeedingWarmUp(for:now:)`` on every trigger
/// (app launch, session end, provider change) and only performs a probe
/// when a host comes back.
public struct LiveStreamWarmTracker: Equatable, Sendable {
    /// How long a completed probe is considered fresh. Chosen to sit above
    /// typical provider DNS TTLs while staying well inside TLS session-ticket
    /// lifetimes, so a user dictating repeatedly re-warms at most once a minute.
    public static let defaultFreshness: TimeInterval = 90

    /// How many times freshness may be renewed while the app stays idle before
    /// the tracker stops asking for a refresh. Warm-up exists to save time on
    /// the next dictation, so an app nobody has touched for several minutes
    /// should stop probing the provider on a timer. The next real trigger —
    /// session end, a settings change, a wake from sleep — clears the tracker
    /// and starts the cycle again.
    public static let maxIdleRefreshes = 5

    private let freshness: TimeInterval
    private let maxIdleRefreshes: Int
    private var warmedHost: String?
    private var warmedAt: Date?
    private var inFlightHost: String?
    private var idleRefreshCount = 0

    public init(
        freshness: TimeInterval = LiveStreamWarmTracker.defaultFreshness,
        maxIdleRefreshes: Int = LiveStreamWarmTracker.maxIdleRefreshes
    ) {
        self.freshness = freshness
        self.maxIdleRefreshes = maxIdleRefreshes
    }

    /// Whether the idle refresh cycle has run its course. The owner keeps
    /// serving on-demand probes; it only stops scheduling new ones.
    public var hasReachedIdleRefreshLimit: Bool {
        self.idleRefreshCount >= self.maxIdleRefreshes
    }

    /// The host that should be warmed now, or `nil` when there is nothing to do.
    ///
    /// The idle cap is deliberately not applied here: a trigger that asks
    /// directly — a device change, for example — still gets its probe, even
    /// after the timer has stopped. One probe on a real event costs little,
    /// and refusing it would make warm-up less useful than the timer it caps.
    public mutating func hostNeedingWarmUp(
        for provider: LiveTranscriptionProviderID?,
        now: Date,
        enabled: Bool = true
    ) -> String? {
        guard enabled, let provider, let host = provider.streamWarmUp.host else {
            self.invalidate()
            return nil
        }
        if self.inFlightHost == host { return nil }
        if self.warmedHost == host, let warmedAt, now.timeIntervalSince(warmedAt) < self.freshness {
            return nil
        }
        self.inFlightHost = host
        return host
    }

    /// Records a completed probe.
    @discardableResult
    public mutating func markWarmed(host: String, at date: Date) -> Bool {
        guard self.inFlightHost == host else { return false }
        self.inFlightHost = nil
        // Warming a host that was already warm means freshness expired while
        // the app sat idle: that is one refresh cycle towards the cap.
        if self.warmedHost == host {
            self.idleRefreshCount += 1
        }
        self.warmedHost = host
        self.warmedAt = date
        return true
    }

    /// Records a failed probe so the next trigger retries it.
    public mutating func markFailed(host: String) {
        guard self.inFlightHost == host else { return }
        self.inFlightHost = nil
        if self.warmedHost == host {
            self.warmedHost = nil
            self.warmedAt = nil
        }
    }

    /// Forgets the probe (provider changed, network changed, disabled) and
    /// gives the idle refresh cycle its full budget again.
    public mutating func invalidate() {
        self.warmedHost = nil
        self.warmedAt = nil
        self.inFlightHost = nil
        self.idleRefreshCount = 0
    }

    /// Whether `host` is currently considered warm at `now`.
    public func isWarm(host: String, now: Date) -> Bool {
        guard self.warmedHost == host, let warmedAt = self.warmedAt else { return false }
        return now.timeIntervalSince(warmedAt) < self.freshness
    }

    /// When the current provider should next be probed, or `nil` when the idle
    /// refresh cycle is over. Owners schedule this deadline so freshness
    /// expires while the app remains otherwise idle.
    public func refreshDeadline(
        for provider: LiveTranscriptionProviderID?,
        enabled: Bool = true
    ) -> Date? {
        guard enabled, !self.hasReachedIdleRefreshLimit else { return nil }
        guard let host = provider?.streamWarmUp.host else { return nil }
        guard self.warmedHost == host, let warmedAt = self.warmedAt else { return nil }
        return warmedAt.addingTimeInterval(self.freshness)
    }
}
