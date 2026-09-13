import Foundation

// MARK: - Shared streaming transcription client pattern
//
// Every cloud live-transcription provider is driven by a single, cross-platform
// WebSocket client that conforms to `StreamingTranscriptionClient`. Both the
// macOS app and the iOS app feed the same client PCM audio captured by their
// own (platform-specific) capture layer, so a provider is implemented once and
// works everywhere. New providers/models added to `ModelCatalog.liveTranscription`
// become available on both platforms as soon as their client is registered here.

/// A provider-agnostic live streaming transcription client.
///
/// Implementations own a single WebSocket session: `start` opens it, `sendAudio`
/// streams linear16 mono PCM at the provider's expected sample rate (see
/// `LiveTranscriptionRoute.sampleRate`), and `stop` tears it down. Transcript
/// updates and errors are delivered through the closures passed to `start`.
public protocol StreamingTranscriptionClient: AnyObject {
    /// How this client's final `onTranscript` events are shaped: standalone
    /// providers emit each finalised segment exactly once, cumulative
    /// providers restate the transcript so far. Consumers must fold finals by
    /// this declaration (`TranscriptAccumulator`), because text equality or
    /// prefixes cannot distinguish a provider resend from two genuinely
    /// identical utterances (issue #700). There is deliberately no default:
    /// every conformer states its provider's documented semantics.
    var finalShape: TranscriptFinalShape { get }

    /// Opens the session.
    /// - Parameters:
    ///   - onTranscript: `(text, isFinal)` for each interim/final transcript.
    ///   - onError: terminal or recoverable transport error.
    func start(
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    )

    /// Streams a chunk of linear16 mono PCM audio.
    func sendAudio(_ audioData: Data)

    /// Closes the session and releases resources.
    func stop()
}

/// Optional signal for clients that know when a provider has closed an
/// utterance. Consumers can use this instead of inferring boundaries from the
/// provider's transcript shape.
public protocol UtteranceBoundaryStreamingClient: StreamingTranscriptionClient {
    var onUtteranceBoundary: ((String) -> Void)? { get set }
}

/// Provider-neutral, immutable view of a streaming session's current result.
public struct StreamingTranscriptSnapshot: Sendable {
    public let confirmedText: String?
    public let pendingInterim: String?
    public let displayText: String?
    public let segments: [TranscriptionSegment]
    public let latestUpdateConfidence: Double?
    public let confidence: Double?
    public let duration: TimeInterval?
    public let cost: ChatCostBreakdown?
    public let rawPayload: String?
    public let isTerminal: Bool

    public init(
        confirmedText: String? = nil,
        pendingInterim: String? = nil,
        displayText: String? = nil,
        segments: [TranscriptionSegment] = [],
        latestUpdateConfidence: Double? = nil,
        confidence: Double? = nil,
        duration: TimeInterval? = nil,
        cost: ChatCostBreakdown? = nil,
        rawPayload: String? = nil,
        isTerminal: Bool = false
    ) {
        self.confirmedText = confirmedText
        self.pendingInterim = pendingInterim
        self.displayText = displayText
        self.segments = segments
        self.latestUpdateConfidence = latestUpdateConfidence
        self.confidence = confidence
        self.duration = duration
        self.cost = cost
        self.rawPayload = rawPayload
        self.isTerminal = isTerminal
    }

    /// Text consumers should present. A provider's explicit display value is
    /// authoritative; otherwise confirmed and interim text are composed.
    public var resolvedDisplayText: String? {
        if let displayText { return displayText }
        guard confirmedText != nil || pendingInterim != nil else { return nil }
        return [confirmedText, pendingInterim]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Optional authoritative result surface for richer streaming providers.
public protocol StreamingTranscriptSnapshotProviding: StreamingTranscriptionClient {
    func transcriptSnapshot(captureDuration: TimeInterval) -> StreamingTranscriptSnapshot
}

/// Optional graceful-finalisation path for providers that only emit their
/// definitive transcript after the input buffer is committed.
///
/// ## Return contract
///
/// `finishAndWait()` returns the **full transcript for the whole session** —
/// never just the trailing segment — or `nil` when the session produced no
/// speech at all. Providers that stream segment-shaped finals accumulate them
/// internally (see `TranscriptAccumulator`) so every conformer answers the same
/// question, and consumers can *replace* their transcript with the return value
/// instead of guessing whether to append it.
///
/// The `onTranscript` callbacks stay provider-shaped (Deepgram/ElevenLabs emit
/// segments, xAI emits cumulative text); only this return value is normalised.
/// `TranscriptAccumulator` is the shared way to fold segment finals into a full
/// transcript on the consumer side.
///
/// `StreamingClientContractTests` asserts this for every conformer.
public protocol FinalizingStreamingTranscriptionClient: StreamingTranscriptionClient {
    /// Commits pending input, waits for the provider's final transcript (with
    /// an implementation-defined timeout), then closes the connection.
    ///
    /// - Returns: the session's full transcript, or `nil` if nothing was
    ///   transcribed. A trailing final consumed here is *not* also delivered
    ///   through `onTranscript`.
    func finishAndWait() async -> String?

    /// Whether `finishAndWait()` actively flushes audio the provider has
    /// received but not yet transcribed (e.g. Deepgram's `CloseStream`).
    ///
    /// When `true` the caller must always finish gracefully, because unseen
    /// words can still arrive. When `false` the call is only a bounded wait for
    /// an already-pending transcript, so a caller with nothing outstanding can
    /// close immediately instead of burning the drain budget.
    var finishFlushesBufferedAudio: Bool { get }
}

public extension FinalizingStreamingTranscriptionClient {
    var finishFlushesBufferedAudio: Bool { true }
}

// MARK: - Errors

public enum LiveTranscriptionClientError: LocalizedError {
    case unknownModel(String)
    case providerNotAvailable(LiveTranscriptionProviderID)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id):
            return "Unrecognised transcription model: \(id)."
        case .providerNotAvailable(let provider):
            return "\(provider.rawValue.capitalized) live transcription isn't available on this device yet."
        }
    }
}

/// Connection/transport errors shared by every `StreamingTranscriptionClient`.
/// A single shared type avoids per-provider error enums colliding with the
/// macOS app's own provider error types.
public enum StreamingClientError: LocalizedError {
    case invalidURL
    case invalidAPIKey(provider: String)
    case missingAPIKey(provider: String)
    /// The socket stopped completing sends while capture continued, so the
    /// outbound audio budget was exhausted. Reported rather than absorbed: the
    /// audio already sent is not being transcribed, and holding the rest in
    /// memory would only make the failure larger.
    case transportStalled(provider: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not build the streaming transcription URL."
        case .invalidAPIKey(let provider):
            return "\(provider) rejected the API key. Check it in Settings."
        case .missingAPIKey(let provider):
            return "\(provider) API key is missing. Please configure it in Settings."
        case .transportStalled(let provider):
            return "The connection to \(provider) stopped accepting audio. "
                + "Check your network and start again."
        }
    }
}
