import Foundation

// MARK: - Streaming provider warm-up policy (issue #663)

/// How far a live-transcription provider's connection may be warmed before the
/// user presses the hotkey.
///
/// Two levels are possible in principle:
///
/// * **Endpoint handshake** — resolve DNS and complete a TLS handshake against
///   the provider's host so the `wss://` upgrade that follows session start
///   skips resolution and can resume the TLS session. No credential is sent,
///   no provider-side session exists, nothing is billed.
/// * **Pre-connect** — open the WebSocket and send the provider's config frame
///   before the hotkey, holding the session open until it is needed.
///
/// Every cloud provider the app supports is ``endpointHandshake`` today, and
/// the reason is the same in each case: the first frame on the socket *is* the
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
    /// Warm DNS + TLS against this host. No credential, no provider session.
    case endpointHandshake(host: String)

    /// The host to warm, when there is one.
    public var host: String? {
        switch self {
        case .unsupported:
            return nil
        case .endpointHandshake(let host):
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
        }
    }

    /// How far this provider's connection may be warmed ahead of a session.
    public var streamWarmUp: LiveStreamWarmUp {
        guard let host = self.streamingHost else { return .unsupported }
        return .endpointHandshake(host: host)
    }
}

// MARK: - Warm tracker

/// Tracks which streaming host has a warm connection and when it goes stale.
///
/// Pure logic so the freshness and re-warm rules are testable without touching
/// the network. The owner asks ``hostNeedingWarmUp(for:now:)`` on every trigger
/// (app launch, session end, provider change) and only performs a handshake
/// when a host comes back.
public struct LiveStreamWarmTracker: Equatable, Sendable {
    /// How long a completed handshake is considered fresh. Chosen to sit above
    /// typical provider DNS TTLs while staying well inside TLS session-ticket
    /// lifetimes, so a user dictating repeatedly re-warms at most once a minute.
    public static let defaultFreshness: TimeInterval = 90

    private let freshness: TimeInterval
    private var warmedHost: String?
    private var warmedAt: Date?
    private var inFlightHost: String?

    public init(freshness: TimeInterval = LiveStreamWarmTracker.defaultFreshness) {
        self.freshness = freshness
    }

    /// The host that should be warmed now, or `nil` when there is nothing to do.
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

    /// Records a completed handshake.
    public mutating func markWarmed(host: String, at date: Date) {
        if self.inFlightHost == host { self.inFlightHost = nil }
        self.warmedHost = host
        self.warmedAt = date
    }

    /// Records a failed handshake so the next trigger retries it.
    public mutating func markFailed(host: String) {
        if self.inFlightHost == host { self.inFlightHost = nil }
        if self.warmedHost == host {
            self.warmedHost = nil
            self.warmedAt = nil
        }
    }

    /// Forgets the warm connection (provider changed, network changed, disabled).
    public mutating func invalidate() {
        self.warmedHost = nil
        self.warmedAt = nil
        self.inFlightHost = nil
    }

    /// Whether `host` is currently considered warm at `now`.
    public func isWarm(host: String, now: Date) -> Bool {
        guard self.warmedHost == host, let warmedAt = self.warmedAt else { return false }
        return now.timeIntervalSince(warmedAt) < self.freshness
    }
}
