import Foundation

/// Published-rate estimates, not provider invoices.
public enum VoiceSynthesisPricing {
    public static let azureNeuralPerThousandCharacters = Decimal(string: "0.016")!

    public static func estimateBasis(for voice: DesktopSpeechVoice) -> String? {
        switch voice {
        case .cartesia: return CartesiaTTSAPI.pricingEstimateBasis
        case .gemini: return GeminiTTSCatalog.pricingEstimateBasis
        case .groq: return GroqTTSCatalog.pricingEstimateBasis
        default: return nil
        }
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
        case .gemini: return nil
        case .groq(let voice): return voice.model.costPerThousandCharacters
        case .speechmatics: return SpeechmaticsTTSAPI.estimatedCostPerThousandCharacters
        case .deepgram(let voice):
            return voice.model == DeepgramSpeechCatalog.flux ? nil : DeepgramTTSAPI.costPerThousandCharacters
        }

    }

    public static func geminiAudioEstimate(duration: TimeInterval?) -> Decimal? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        return Decimal(duration) * GeminiTTSCatalog.defaultModel.costPerSecondOfSpeech
    }

    public static func geminiInputEstimate(reportedTokens: Int?) -> Decimal? {
        guard let reportedTokens, reportedTokens >= 0 else { return nil }
        return Decimal(reportedTokens) * GeminiTTSCatalog.defaultModel.costPerInputToken
    }

    public static func estimate(for voice: DesktopSpeechVoice, characterCount: Int) -> Decimal? {
        estimate(for: voice, characterCount: characterCount, xaiInventory: nil)
    }

    public static func estimate(
        for voice: DesktopSpeechVoice, text: String, xaiInventory: XAIAccountVoiceInventory? = nil
    ) throws -> Decimal? {
        let count: Int
        if case .groq = voice {
            do {
                count = try GroqTTSAPI.synthesisSegments(text).reduce(0) { $0 + $1.count }
            } catch let error as GroqTTSAPIError {
                throw DesktopGroqSpeechError(error)
            }
        } else if case .speechmatics = voice {
            count = SpeechTextSegmenter.segments(text).reduce(0) { $0 + $1.count }
        } else {
            count = text.unicodeScalars.count
        }
        return estimate(for: voice, characterCount: count, xaiInventory: xaiInventory)
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
