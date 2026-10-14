import Foundation

/// Only routes the portable desktop synthesis engine executes, not every voice
/// a provider or another platform can offer.
public enum DesktopSpeechVoice: Hashable, Sendable {
    case deepgram(DeepgramSpeechCatalog.Voice)
    case azureNeural(AzureNeuralVoice)
    case azureMAI(AzureMAIVoice)
    case xai(XAITTSVoice)
    case cartesia(CartesiaTTSVoice)
    case gemini(GeminiTTSVoice)
    case groq(GroqTTSVoice)
    case speechmatics(SpeechmaticsTTSVoice)
    case openai(OpenAITTSModel, OpenAITTSVoice)
    case mistral(MistralTTSVoice)

    public var id: String {
        switch self {
        case .deepgram(let voice): voice.id
        case .azureNeural(let voice): voice.id
        case .azureMAI(let voice): voice.id
        case .xai(let voice): voice.providerVoiceID
        case .cartesia(let voice): voice.providerVoiceID
        case .gemini(let voice): voice.providerVoiceID
        case .groq(let voice): voice.providerVoiceID
        case .speechmatics(let voice): voice.providerVoiceID
        case .openai(_, let voice): voice.providerVoiceID
        case .mistral(let voice): voice.providerVoiceID
        }
    }

    public var name: String {
        switch self {
        case .deepgram(let voice): voice.name
        case .azureNeural(let voice): voice.name
        case .azureMAI(let voice): voice.displayName
        case .xai(let voice): voice.displayName
        case .cartesia(let voice): voice.displayName
        case .gemini(let voice): voice.displayName
        case .groq(let voice): voice.displayName
        case .speechmatics(let voice): voice.displayName
        case .openai(_, let voice): voice.name
        case .mistral(let voice): voice.displayName
        }
    }

    public var modelID: String {
        switch self {
        case .deepgram(let voice): voice.model.id
        case .azureNeural: "azure/neural"
        case .azureMAI(let voice): voice.model.rawValue
        case .xai: XAITTSCatalog.providerIdentifier
        case .cartesia: CartesiaTTSCatalog.desktopModelIdentifier
        case .gemini: GeminiTTSCatalog.desktopModelIdentifier
        case .groq(let voice): voice.model.desktopModelIdentifier
        case .speechmatics: SpeechmaticsTTSCatalog.providerIdentifier
        case .openai(let model, _): model.desktopModelIdentifier
        case .mistral: MistralTTSCatalog.defaultModel.desktopModelIdentifier
        }
    }

    public var label: String {
        switch self {
        case .deepgram(let voice): "\(voice.displayName) — \(voice.model.displayName)"
        case .azureNeural(let voice): "\(voice.name) — Azure Speech (\(voice.shortName))"
        case .azureMAI(let voice): "\(voice.displayName) — Azure Speech"
        case .xai(let voice): "\(voice.displayName) — xAI Speech"
        case .cartesia(let voice):
            "\(voice.displayName) — Cartesia \(CartesiaTTSCatalog.defaultModel.displayName)"
        case .gemini(let voice): "\(voice.displayName) — \(GeminiTTSCatalog.defaultModel.displayName)"
        case .groq(let voice): "\(voice.displayName) — Groq"
        case .speechmatics(let voice): "\(voice.displayName) — Speechmatics English"
        case .openai(let model, let voice): "\(voice.name) — OpenAI \(model.displayName)"
        case .mistral(let voice): "\(voice.displayName) — Mistral \(MistralTTSCatalog.defaultModel.displayName)"
        }
    }

    public var apiKeyIdentifier: String {
        switch self {
        case .deepgram: VoiceOutputProvider.deepgram.apiKeyIdentifier
        case .azureNeural, .azureMAI: AzureSpeechConfiguration.credentialIdentifier
        case .xai: XAITTSCatalog.credentialIdentifier
        case .cartesia: CartesiaTTSCatalog.credentialIdentifier
        case .gemini: GeminiTTSCatalog.credentialIdentifier
        case .groq: GroqTTSCatalog.credentialIdentifier
        case .speechmatics: SpeechmaticsTTSCatalog.credentialIdentifier
        case .openai: OpenAITTSCatalog.credentialIdentifier
        case .mistral: MistralTTSCatalog.credentialIdentifier
        }
    }

    public var capabilities: VoiceSynthesisCapabilities {
        switch self {
        case .deepgram: .naturalSpeech
        case .azureNeural: .azureNeural
        case .azureMAI: .azureMAI
        case .xai: .xai
        case .cartesia: .cartesia
        case .gemini, .groq, .speechmatics, .mistral: .naturalSpeech
        case .openai: .openai
        }
    }

    public var sampleRate: Int {
        if case .speechmatics = self { return SpeechmaticsTTSOutputFormat.wav16k.sampleRate }
        return 24_000
    }

    public static var voices: [Self] {
        var voices = DeepgramSpeechCatalog.voices.map(Self.deepgram)
        voices.append(contentsOf: AzureNeuralVoiceCatalog.voices.map(Self.azureNeural))
        voices.append(contentsOf: AzureMAIVoiceCatalog.voices.map(Self.azureMAI))
        voices.append(contentsOf: XAITTSCatalog.voices.map(Self.xai))
        voices.append(contentsOf: CartesiaTTSCatalog.voices.map(Self.cartesia))
        voices.append(contentsOf: GeminiTTSCatalog.voices.map(Self.gemini))
        voices.append(contentsOf: GroqTTSCatalog.voices.map(Self.groq))
        voices.append(contentsOf: SpeechmaticsTTSCatalog.voices.map(Self.speechmatics))
        for model in OpenAITTSCatalog.models {
            voices.append(contentsOf: OpenAITTSCatalog.voices(for: model).map { Self.openai(model, $0) })
        }
        return voices
    }

    public static func resolved(
        modelID: String?, voiceID: String?
    ) throws -> Self {
        try resolved(modelID: modelID, voiceID: voiceID, xaiInventory: nil)
    }

    public static func resolved(
        modelID: String?, voiceID: String?, xaiInventory: XAIAccountVoiceInventory?
    ) throws -> Self {
        try resolved(modelID: modelID, voiceID: voiceID, accountInventory: xaiInventory.map(VoiceAccountInventory.xai))
    }

    public static func resolved(
        modelID: String?, voiceID: String?, accountInventory: VoiceAccountInventory?
    ) throws -> Self {
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identifier = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let voice = try fixedProviderSelection(model: model, identifier: identifier) {
            return voice
        }
        if let voice = try accountSelection(model: model, identifier: identifier,
            original: voiceID?.trimmingCharacters(in: .whitespacesAndNewlines), inventory: accountInventory) {
            return voice
        }
        let maiModel = model?.hasPrefix(AzureMAIVoiceCatalog.modelMarker.dropFirst().lowercased()) == true
        if model?.hasPrefix("azure/") == true || identifier?.hasPrefix("azure/") == true || maiModel {
            if let voice = AzureMAIVoiceCatalog.voices.first(where: { $0.id.lowercased() == identifier }) {
                // Existing Azure imports can carry the old route identifier;
                // the canonical MAI model is selected by the voice-name suffix.
                guard model == nil || model == "azure/neural" || model == voice.model.rawValue.lowercased() else {
                    throw VoiceSynthesisConfigurationError.unsupportedVoice
                }
                return .azureMAI(voice)
            }
            guard let voice = AzureNeuralVoiceCatalog.voices.first(where: { $0.id.lowercased() == identifier }),
                  model == nil || model == "azure/neural" else {
                throw VoiceSynthesisConfigurationError.unsupportedVoice
            }
            return .azureNeural(voice)
        }
        // Retain Deepgram's existing short-name and retired-model migrations,
        // but never route another provider's explicit identifier to Deepgram.
        if let identifier, identifier.contains("/"), !identifier.hasPrefix("deepgram/") {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        if let model, model.contains("/"), !model.hasPrefix("deepgram/") {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .deepgram(DeepgramSpeechCatalog.resolvedSelection(modelID: modelID, voiceID: voiceID).voice)
    }

    private static func fixedProviderSelection(model: String?, identifier: String?) throws -> Self? {
        try openaiSelection(model: model, identifier: identifier)
            ?? speechmaticsSelection(model: model, identifier: identifier)
            ?? groqSelection(model: model, identifier: identifier)
            ?? geminiSelection(model: model, identifier: identifier)
            ?? cartesiaSelection(model: model, identifier: identifier)
    }

    private static func openaiSelection(model: String?, identifier: String?) throws -> Self? {
        guard model == OpenAITTSCatalog.providerIdentifier
            || model?.hasPrefix(OpenAITTSCatalog.voiceIDPrefix) == true
            || OpenAITTSCatalog.models.contains(where: { $0.rawValue == model })
            || identifier?.hasPrefix(OpenAITTSCatalog.voiceIDPrefix) == true else { return nil }
        let selected: OpenAITTSModel
        if model == nil || model == OpenAITTSCatalog.providerIdentifier {
            selected = OpenAITTSCatalog.defaultModel
        } else {
            guard let found = OpenAITTSCatalog.models.first(where: {
                $0.rawValue == model || $0.desktopModelIdentifier == model
            }) else { throw VoiceSynthesisConfigurationError.unsupportedVoice }
            selected = found
        }
        guard let identifier, let voice = OpenAITTSCatalog.voice(forID: identifier), voice.supports(selected) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .openai(selected, voice)
    }

    private static func speechmaticsSelection(model: String?, identifier: String?) throws -> Self? {
        guard model == SpeechmaticsTTSCatalog.providerIdentifier
            || model?.hasPrefix(SpeechmaticsTTSCatalog.voiceIDPrefix) == true
            || identifier?.hasPrefix(SpeechmaticsTTSCatalog.voiceIDPrefix) == true else { return nil }
        guard model == nil || model == SpeechmaticsTTSCatalog.providerIdentifier,
              let identifier, let voice = SpeechmaticsTTSCatalog.voice(forID: identifier) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .speechmatics(voice)
    }

    private static func geminiSelection(model: String?, identifier: String?) throws -> Self? {
        guard model == GeminiTTSCatalog.providerIdentifier
            || model?.hasPrefix(GeminiTTSCatalog.voiceIDPrefix) == true
            || model?.hasPrefix("gemini-") == true
            || identifier?.hasPrefix(GeminiTTSCatalog.voiceIDPrefix) == true else { return nil }
        guard model == nil || model == GeminiTTSCatalog.providerIdentifier
            || model == GeminiTTSCatalog.desktopModelIdentifier
            || model == GeminiTTSCatalog.defaultModel.rawValue,
            let identifier, let voice = GeminiTTSCatalog.voice(forID: identifier) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }

        return .gemini(voice)
    }

    private static func groqSelection(model: String?, identifier: String?) throws -> Self? {
        guard model == GroqTTSCatalog.providerIdentifier
            || model?.hasPrefix(GroqTTSCatalog.voiceIDPrefix) == true
            || model?.hasPrefix("canopylabs/") == true
            || model?.hasPrefix("playai-tts") == true
            || identifier?.hasPrefix(GroqTTSCatalog.voiceIDPrefix) == true else { return nil }
        guard let identifier,
              let voice = GroqTTSCatalog.voices.first(where: {
                  $0.providerVoiceID == identifier || $0.apiVoiceID == identifier
              }),
              model == nil || model == GroqTTSCatalog.providerIdentifier
                  || model == voice.model.rawValue || model == voice.model.desktopModelIdentifier else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .groq(voice)
    }

    private static func cartesiaSelection(model: String?, identifier: String?) throws -> Self? {
        guard model == CartesiaTTSCatalog.providerIdentifier
            || model?.hasPrefix(CartesiaTTSCatalog.voiceIDPrefix) == true
            || identifier?.hasPrefix(CartesiaTTSCatalog.voiceIDPrefix) == true
            || CartesiaTTSCatalog.models.contains(where: { $0.rawValue == model }) else { return nil }
        guard model == nil || model == CartesiaTTSCatalog.providerIdentifier
            || model == CartesiaTTSCatalog.desktopModelIdentifier
            || model == CartesiaTTSCatalog.defaultModel.rawValue,
            let identifier, let voice = CartesiaTTSCatalog.voice(forID: identifier) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .cartesia(voice)
    }

}
