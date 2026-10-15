import Foundation

/// Published character-rate estimates, not provider invoices or token usage.
public enum VoiceSynthesisPricing {
    public static let azureNeuralPerThousandCharacters = Decimal(string: "0.016")!

    public static func estimateBasis(for voice: DesktopSpeechVoice) -> String? {
        switch voice {
        case .cartesia: return CartesiaTTSAPI.pricingEstimateBasis
        case .mistral:
            return "Mistral estimates use the canonical character rate and submitted graphemes after segmentation. "
                + "Observed input Unicode scalars can differ from graphemes and provider billing counts. "
                + "No tokens or billing receipts are reported; estimates are not charges."
        default: return nil
        }
    }

    public static func ratePerThousandCharacters(for voice: DesktopSpeechVoice) -> Decimal? {
        ratePerThousandCharacters(for: voice, xaiInventory: nil)
    }

    public static func ratePerThousandCharacters(
        for voice: DesktopSpeechVoice, xaiInventory: XAIAccountVoiceInventory?
    ) -> Decimal? {
        ratePerThousandCharacters(for: voice, accountInventory: xaiInventory.map(VoiceAccountInventory.xai))
    }

    public static func ratePerThousandCharacters(
        for voice: DesktopSpeechVoice, accountInventory: VoiceAccountInventory?
    ) -> Decimal? {
        guard DesktopSpeechVoice.voices.contains(voice) || accountInventory?.contains(voice) == true else { return nil }
        switch voice {
        case .azureNeural: return azureNeuralPerThousandCharacters
        case .azureMAI: return AzureMAIVoiceCatalog.costPerThousandCharacters(forVoiceID: voice.id)
        case .xai: return XAITTSAPI.estimatedCostPerThousandCharacters
        case .cartesia: return CartesiaTTSAPI.estimatedCostPerThousandCharacters
        case .mistral: return MistralTTSAPI.estimatedCostPerThousandCharacters
        case .deepgram(let voice):
            return voice.model == DeepgramSpeechCatalog.flux ? nil : DeepgramTTSAPI.costPerThousandCharacters
        }
    }

    public static func estimate(for voice: DesktopSpeechVoice, characterCount: Int) -> Decimal? {
        estimate(for: voice, characterCount: characterCount, xaiInventory: nil)
    }

    public static func estimate(
        for voice: DesktopSpeechVoice, text: String, xaiInventory: XAIAccountVoiceInventory? = nil
    ) -> Decimal? {
        estimate(for: voice, text: text, accountInventory: xaiInventory.map(VoiceAccountInventory.xai))
    }

    public static func estimate(
        for voice: DesktopSpeechVoice, text: String, accountInventory: VoiceAccountInventory?
    ) -> Decimal? {
        let count: Int
        if case .mistral = voice {
            count = TTSTextChunker.chunks(text, maximumCharacters: MistralTTSAPI.maxInputCharacters)
                .reduce(0) { $0 + $1.count }
        } else {
            count = text.unicodeScalars.count
        }
        return estimate(for: voice, characterCount: count, accountInventory: accountInventory)
    }

    public static func estimate(
        for voice: DesktopSpeechVoice, characterCount: Int, xaiInventory: XAIAccountVoiceInventory?
    ) -> Decimal? {
        estimate(for: voice, characterCount: characterCount,
                 accountInventory: xaiInventory.map(VoiceAccountInventory.xai))
    }

    public static func estimate(
        for voice: DesktopSpeechVoice, characterCount: Int, accountInventory: VoiceAccountInventory?
    ) -> Decimal? {
        guard characterCount >= 0 else { return nil }
        return ratePerThousandCharacters(for: voice, accountInventory: accountInventory).map {
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
