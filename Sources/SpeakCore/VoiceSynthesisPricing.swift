import Foundation

/// Published character-rate estimates, not provider invoices or token usage.
public enum VoiceSynthesisPricing {
    public static let azureNeuralPerThousandCharacters = Decimal(string: "0.016")!

    public static func ratePerThousandCharacters(for voice: DesktopSpeechVoice) -> Decimal? {
        guard DesktopSpeechVoice.voices.contains(voice) else { return nil }
        switch voice {
        case .azureNeural: return azureNeuralPerThousandCharacters
        case .azureMAI: return AzureMAIVoiceCatalog.costPerThousandCharacters(forVoiceID: voice.id)
        case .deepgram(let voice):
            return voice.model == DeepgramSpeechCatalog.flux ? nil : DeepgramTTSAPI.costPerThousandCharacters
        }
    }

    public static func estimate(for voice: DesktopSpeechVoice, characterCount: Int) -> Decimal? {
        guard characterCount >= 0 else { return nil }
        return ratePerThousandCharacters(for: voice).map { Decimal(characterCount) * $0 / 1_000 }
    }
}

/// Shared configuration metadata. Desktop hosts store this in their sole Voice settings model.
public enum VoiceUsagePolicy {
    public static let trackingPreferenceKey = "ttsTrackUsage"
    public static let defaultTrackingEnabled = true
    public static let trackingLabel = "Keep local synthesis usage"
    public static let maximumRetainedRequests = 1_000
}
