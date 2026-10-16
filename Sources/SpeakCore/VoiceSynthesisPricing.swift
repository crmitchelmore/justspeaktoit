import Foundation

/// Published-rate estimates, not provider invoices.
public enum VoiceSynthesisPricing {
    public static let azureNeuralPerThousandCharacters = Decimal(string: "0.016")!

    public static func estimateBasis(for voice: DesktopSpeechVoice) -> String? {
        switch voice {
        case .elevenlabs: return ElevenLabsTTSAPI.pricingEstimateBasis
        case .cartesia: return CartesiaTTSAPI.pricingEstimateBasis
        case .gemini: return GeminiTTSCatalog.pricingEstimateBasis
        case .groq: return GroqTTSCatalog.pricingEstimateBasis
        case .openai(.mini, _):
            return "OpenAI mini TTS uses text/audio token pricing. Binary WAV responses report no usage tokens "
                + "or billing receipts; characters and PCM duration are not token counts. Charges are unestimated."
        case .openai:
            return "OpenAI TTS-1/HD estimates use submitted characters after segmentation. "
                + "Observed Unicode scalars and provider billing counts may differ; estimates are not charges."
        case .mistral:
            return "Mistral estimates use the canonical character rate and submitted graphemes after segmentation. "
                + "Observed input Unicode scalars can differ from graphemes and provider billing counts. "
                + "No tokens or billing receipts are reported; estimates are not charges."
        case .soniox:
            return "Soniox estimates use the canonical approximate character rate after segmentation. "
                + "Measured audio duration is retained separately; estimates are not invoices or token counts."
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
        case .soniox: return SonioxTTSAPI.estimatedCostPerThousandCharacters
        case .gemini: return nil
        case .groq(let voice): return voice.model.costPerThousandCharacters
        case .speechmatics: return SpeechmaticsTTSAPI.estimatedCostPerThousandCharacters
        case .openai(let model, _): return model.costPerThousandCharacters
        case .elevenlabs: return ElevenLabsTTSAPI.estimatedCostPerThousandCharacters
        case .deepgram(let voice):
            return voice.model == DeepgramSpeechCatalog.flux ? nil : DeepgramTTSAPI.costPerThousandCharacters
        }
    }

    public static func estimate(for voice: DesktopSpeechVoice, characterCount: Int) -> Decimal? {
        estimate(for: voice, characterCount: characterCount, xaiInventory: nil)
    }

    public static func estimate(
        for voice: DesktopSpeechVoice, text: String, xaiInventory: XAIAccountVoiceInventory? = nil
    ) throws -> Decimal? {
        try estimate(for: voice, text: text, accountInventory: xaiInventory.map(VoiceAccountInventory.xai))
    }

    public static func estimate(
        for voice: DesktopSpeechVoice, text: String, accountInventory: VoiceAccountInventory?
    ) throws -> Decimal? {
        let count: Int
        if case .mistral = voice {
            count = TTSTextChunker.chunks(text, maximumCharacters: MistralTTSAPI.maxInputCharacters)
                .reduce(0) { $0 + $1.count }
        } else if case .soniox = voice {
            count = TTSTextChunker.chunks(text, maximumCharacters: SonioxTTSAPI.maxTextLength)
                .reduce(0) { $0 + $1.count }
        } else if case .groq = voice {
            do {
                count = try GroqTTSAPI.synthesisSegments(text).reduce(0) { $0 + $1.count }
            } catch let error as GroqTTSAPIError {
                throw DesktopGroqSpeechError(error)
            }
        } else if case .speechmatics = voice {
            count = SpeechTextSegmenter.segments(text).reduce(0) { $0 + $1.count }
        } else if case .openai = voice {
            count = try OpenAITTSAPI.synthesisSegments(text).reduce(0) { $0 + $1.count }
        } else if case .elevenlabs(let model, let preset) = voice {
            count = try DesktopElevenLabsSpeechSynthesis.pricingCharacterCount(text: text, model: model, voice: preset)
        } else {
            count = text.unicodeScalars.count
        }
        return estimate(for: voice, characterCount: count, accountInventory: accountInventory)
    }

    public static func geminiAudioEstimate(
        duration: TimeInterval?, model: GeminiTTSModel = GeminiTTSCatalog.defaultModel
    ) -> Decimal? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        return Decimal(duration) * model.costPerSecondOfSpeech
    }

    public static func geminiInputEstimate(
        reportedTokens: Int?, model: GeminiTTSModel = GeminiTTSCatalog.defaultModel
    ) -> Decimal? {
        guard let reportedTokens, reportedTokens >= 0 else { return nil }
        return Decimal(reportedTokens) * model.costPerInputToken
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
