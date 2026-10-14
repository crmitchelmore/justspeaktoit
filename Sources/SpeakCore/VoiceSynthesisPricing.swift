import Foundation

/// Published character-rate estimates, not provider invoices or token usage.
public enum VoiceSynthesisPricing {
    public static let azureNeuralPerThousandCharacters = Decimal(string: "0.016")!

    public static func estimateBasis(for voice: DesktopSpeechVoice) -> String? {
        guard case .cartesia = voice else { return nil }
        return CartesiaTTSAPI.pricingEstimateBasis
    }

    public static func ratePerThousandCharacters(for voice: DesktopSpeechVoice) -> Decimal? {
        ratePerThousandCharacters(for: voice, xaiInventory: nil)
    }

    public static func ratePerThousandCharacters(
        for voice: DesktopSpeechVoice, xaiInventory: XAIAccountVoiceInventory?
    ) -> Decimal? {
        guard DesktopSpeechVoice.voices.contains(voice) || xaiInventory?.contains(voice) == true else { return nil }
        switch voice {
        case .azureNeural: return azureNeuralPerThousandCharacters
        case .azureMAI: return AzureMAIVoiceCatalog.costPerThousandCharacters(forVoiceID: voice.id)
        case .xai: return XAITTSAPI.estimatedCostPerThousandCharacters
        case .cartesia: return CartesiaTTSAPI.estimatedCostPerThousandCharacters
        case .deepgram(let voice):
            return voice.model == DeepgramSpeechCatalog.flux ? nil : DeepgramTTSAPI.costPerThousandCharacters
        }
    }

    public static func estimate(for voice: DesktopSpeechVoice, characterCount: Int) -> Decimal? {
        estimate(for: voice, characterCount: characterCount, xaiInventory: nil)
    }

    public static func estimate(
        for voice: DesktopSpeechVoice, characterCount: Int, xaiInventory: XAIAccountVoiceInventory?
    ) -> Decimal? {
        guard characterCount >= 0 else { return nil }
        return ratePerThousandCharacters(for: voice, xaiInventory: xaiInventory).map {
            Decimal(characterCount) * $0 / 1_000
        }
    }
}

/// Shared configuration metadata. Desktop hosts store this in their sole Voice settings model.
public enum VoiceUsagePolicy {
    public static let trackingPreferenceKey = "ttsTrackUsage"
    public static let defaultTrackingEnabled = true
    public static let trackingLabel = "Keep local synthesis usage"
    public static let maximumRetainedRequests = 1_000
}
