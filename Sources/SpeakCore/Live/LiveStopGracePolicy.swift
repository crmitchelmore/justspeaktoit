import Foundation

/// The user's extra stop grace (`LiveClientOptions.stopGracePeriod`) as a host
/// applies it to a shared live client.
///
/// Cartesia, AssemblyAI and Gladia fold the grace into their own finish timing,
/// so a host adds nothing for them. Deepgram, Soniox, Modulate and OpenAI wait
/// the grace on the host after capture stops and before finalising, so the
/// provider can still deliver finals for the trailing audio. ElevenLabs bounds
/// that wait to two seconds because its finish already drains for longer. Every
/// other provider has never waited, and still does not.
public enum LiveStopGracePolicy {
    public static let maximumElevenLabsGrace: TimeInterval = 2

    /// Seconds a host waits between stopping capture and finalising `provider`.
    public static func hostDelay(for provider: LiveTranscriptionProviderID, grace: TimeInterval) -> TimeInterval {
        guard grace.isFinite, grace > 0 else { return 0 }
        switch provider {
        case .deepgram, .soniox, .modulate, .openai:
            return grace
        case .elevenlabs:
            return min(grace, maximumElevenLabsGrace)
        case .apple, .cartesia, .assemblyai, .gladia, .google, .xai, .azure, .alibaba, .meta,
             .speechmatics, .revai, .mistral, .reson8:
            return 0
        }
    }

    /// The outer stop watchdog. It outlives the provider's finalisation budget
    /// plus the host delay, with one second for terminal delivery through the
    /// main actor, and is never shorter than the ten seconds every host used
    /// before budgets existed. It is a maximum, never a sleep on success.
    public static func completionTimeout(finalisationBudget: TimeInterval?, hostDelay: TimeInterval) -> TimeInterval {
        let delay = hostDelay.isFinite ? max(hostDelay, 0) : 0
        guard let budget = finalisationBudget, budget.isFinite, budget > 0 else { return 10 + delay }
        return max(10, budget + delay + 1)
    }
}
