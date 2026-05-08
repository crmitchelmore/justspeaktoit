import Foundation

/// Identifiers for the user-facing "Processing Speed" modes.
///
/// This lives in `SpeakCore` (rather than alongside `AppSettings.SpeedMode`)
/// so that the model catalogue can declare which modes a model supports
/// without taking a dependency on the macOS app target.
///
/// Raw values intentionally match `AppSettings.SpeedMode.rawValue` so the two
/// enums can be bridged 1:1 by raw value.
public enum SpeedModeID: String, Sendable, CaseIterable, Hashable {
    case instant
    case livePolish
}

/// Per-model capabilities that influence the live transcription pipeline.
public struct LiveModelCapabilities: Sendable, Hashable {
    /// The set of `SpeedModeID`s this model supports. `instant` is always
    /// supported — it represents the raw passthrough of the provider's
    /// transcript with no live LLM rewriting.
    public let supportedSpeedModes: Set<SpeedModeID>

    /// How long the live controller should wait, after the user stops
    /// recording, for the provider to deliver its final transcript.
    ///
    /// Most streaming providers (Deepgram, Soniox, ElevenLabs) finalise
    /// during the session, so the budget is 0. AssemblyAI's Universal
    /// Streaming v3 with `format_turns=true` only commits text on
    /// end-of-turn and runs a server-side formatting pass over the whole
    /// turn, so its budget is non-zero.
    public let postStopFinalizeBudget: TimeInterval

    public init(
        supportedSpeedModes: Set<SpeedModeID>,
        postStopFinalizeBudget: TimeInterval = 0
    ) {
        self.supportedSpeedModes = supportedSpeedModes
        self.postStopFinalizeBudget = postStopFinalizeBudget
    }

    /// The default for any model that doesn't appear in the lookup table:
    /// instant only, no finalisation wait.
    public static let `default` = LiveModelCapabilities(
        supportedSpeedModes: [.instant],
        postStopFinalizeBudget: 0
    )
}

extension ModelCatalog {
    /// Look up the live transcription capabilities for the given model id.
    ///
    /// Unknown ids fall back to `LiveModelCapabilities.default` (instant only).
    public static func liveCapabilities(for modelID: String) -> LiveModelCapabilities {
        if let exact = liveCapabilityRegistry[modelID] {
            return exact
        }
        // Conservative fallback: any other model is treated as instant-only.
        // Add explicit entries above to opt a model into richer modes.
        return .default
    }

    /// Explicit per-model capability registry. Keep in sync with
    /// `ModelCatalog.liveTranscription`.
    private static let liveCapabilityRegistry: [String: LiveModelCapabilities] = [
        // Apple on-device — raw passthrough only.
        "apple/local/SFSpeechRecognizer": .default,
        "apple/local/Dictation": .default,

        // Streaming providers that emit incremental finals during the session.
        // Live Polish is supported because MainManager's incremental tail
        // rewrite pipeline only needs incremental text updates.
        "deepgram/nova-3-streaming": LiveModelCapabilities(
            supportedSpeedModes: [.instant, .livePolish]
        ),
        "modulate/velma-2-stt-streaming": LiveModelCapabilities(
            supportedSpeedModes: [.instant, .livePolish]
        ),
        "soniox/stt-rt-preview-streaming": LiveModelCapabilities(
            supportedSpeedModes: [.instant, .livePolish]
        ),
        "elevenlabs/scribe-v2-streaming": LiveModelCapabilities(
            supportedSpeedModes: [.instant, .livePolish]
        ),

        // AssemblyAI Universal Streaming v3: incremental turns are emitted
        // during the session, but the *formatted* final turn is produced
        // server-side after end-of-turn. We therefore need a non-zero
        // post-stop budget so the controller can wait for that formatted
        // turn before tearing the socket down.
        "assemblyai/u3-rt-pro-streaming": LiveModelCapabilities(
            supportedSpeedModes: [.instant, .livePolish],
            postStopFinalizeBudget: 2.0
        ),

        // OpenAI Realtime gpt-realtime-whisper: emits incremental
        // transcription deltas during the session and a per-item completed
        // event. We use a small post-stop budget to wait for the in-flight
        // commit to round-trip, then close the socket.
        "openai/gpt-realtime-whisper-streaming": LiveModelCapabilities(
            supportedSpeedModes: [.instant, .livePolish],
            postStopFinalizeBudget: 0.5
        )
    ]
}
