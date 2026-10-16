import Foundation

/// Only routes the portable desktop synthesis engine executes, not every voice
/// a provider or another platform can offer.
public enum DesktopSpeechVoice: Hashable, Sendable {
    case deepgram(DeepgramSpeechCatalog.Voice)
    case azureNeural(AzureNeuralVoice)
    case azureMAI(AzureMAIVoice)
    case xai(XAITTSVoice)
    case cartesia(CartesiaTTSVoice)
    case mistral(MistralTTSVoice)
    case soniox(SonioxTTSResolvedVoice)
    case gemini(GeminiTTSVoice, model: GeminiTTSModel = GeminiTTSCatalog.defaultModel)
    case groq(GroqTTSVoice)
    case speechmatics(SpeechmaticsTTSVoice)
    case openai(OpenAITTSModel, OpenAITTSVoice)
    case elevenlabs(ElevenLabsTTSModels.Model, ElevenLabsTTSVoice)

    public var id: String {
        switch self {
        case .deepgram(let voice): voice.id
        case .azureNeural(let voice): voice.id
        case .azureMAI(let voice): voice.id
        case .xai(let voice): voice.providerVoiceID
        case .cartesia(let voice): voice.providerVoiceID
        case .mistral(let voice): voice.providerVoiceID
        case .soniox(let voice): voice.providerVoiceID
        case .gemini(let voice, _): voice.providerVoiceID
        case .groq(let voice): voice.providerVoiceID
        case .speechmatics(let voice): voice.providerVoiceID
        case .openai(_, let voice): voice.providerVoiceID
        case .elevenlabs(_, let voice): voice.providerVoiceID
        }
    }

    public var name: String {
        switch self {
        case .deepgram(let voice): voice.name
        case .azureNeural(let voice): voice.name
        case .azureMAI(let voice): voice.displayName
        case .xai(let voice): voice.displayName
        case .cartesia(let voice): voice.displayName
        case .mistral(let voice): voice.displayName
        case .soniox(let voice): voice.displayName
        case .gemini(let voice, _): voice.displayName
        case .groq(let voice): voice.displayName
        case .speechmatics(let voice): voice.displayName
        case .openai(_, let voice): voice.name
        case .elevenlabs(_, let voice): voice.displayName
        }
    }

    public var modelID: String {
        switch self {
        case .deepgram(let voice): voice.model.id
        case .azureNeural: "azure/neural"
        case .azureMAI(let voice): voice.model.rawValue
        case .xai: XAITTSCatalog.providerIdentifier
        case .cartesia: CartesiaTTSCatalog.desktopModelIdentifier
        case .mistral: MistralTTSCatalog.defaultModel.desktopModelIdentifier
        case .soniox: SonioxTTSCatalog.defaultModel.rawValue
        case .gemini(_, let model): model.desktopModelIdentifier
        case .groq(let voice): voice.model.desktopModelIdentifier
        case .speechmatics: SpeechmaticsTTSCatalog.providerIdentifier
        case .openai(let model, _): model.desktopModelIdentifier
        case .elevenlabs(let model, _): model.desktopModelIdentifier
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
        case .mistral(let voice): "\(voice.displayName) — Mistral \(MistralTTSCatalog.defaultModel.displayName)"
        case .soniox(let voice): "\(voice.displayName) — \(SonioxTTSCatalog.defaultModel.displayName)"
        case .gemini(let voice, let model): "\(voice.displayName) — \(model.displayName)"
        case .groq(let voice): "\(voice.displayName) — Groq"
        case .speechmatics(let voice): "\(voice.displayName) — Speechmatics English"
        case .openai(let model, let voice): "\(voice.name) — OpenAI \(model.displayName)"
        case .elevenlabs(let model, let voice): "\(voice.displayName) — \(model.displayName)"
        }
    }

    public var apiKeyIdentifier: String {
        switch self {
        case .deepgram: VoiceOutputProvider.deepgram.apiKeyIdentifier
        case .azureNeural, .azureMAI: AzureSpeechConfiguration.credentialIdentifier
        case .xai: XAITTSCatalog.credentialIdentifier
        case .cartesia: CartesiaTTSCatalog.credentialIdentifier
        case .mistral: MistralTTSCatalog.credentialIdentifier
        case .soniox: VoiceOutputProvider.soniox.apiKeyIdentifier
        case .gemini: GeminiTTSCatalog.credentialIdentifier
        case .groq: GroqTTSCatalog.credentialIdentifier
        case .speechmatics: SpeechmaticsTTSCatalog.credentialIdentifier
        case .openai: OpenAITTSCatalog.credentialIdentifier
        case .elevenlabs: ElevenLabsTTSCatalog.credentialIdentifier
        }
    }

    public var capabilities: VoiceSynthesisCapabilities {
        switch self {
        case .deepgram: .naturalSpeech
        case .azureNeural: .azureNeural
        case .azureMAI: .azureMAI
        case .xai: .xai
        case .cartesia: .cartesia
        case .mistral: .naturalSpeech
        case .soniox: .soniox
        case .gemini, .groq, .speechmatics: .naturalSpeech
        case .openai: .openai
        case .elevenlabs: .naturalSpeech
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
        voices.append(contentsOf: SonioxTTSCatalog.voices.map {
            .soniox(SonioxTTSCatalog.resolvedVoice(voiceID: $0.providerVoiceID, accountVoices: []))
        })
        for model in GeminiTTSCatalog.models {
            voices.append(contentsOf: GeminiTTSCatalog.voices.map { Self.gemini($0, model: model) })
        }
        voices.append(contentsOf: GroqTTSCatalog.voices.map(Self.groq))
        voices.append(contentsOf: SpeechmaticsTTSCatalog.voices.map(Self.speechmatics))
        for model in OpenAITTSCatalog.models {
            voices.append(contentsOf: OpenAITTSCatalog.voices(for: model).map { Self.openai(model, $0) })
        }
        for model in ElevenLabsTTSModels.all {
            voices.append(contentsOf: ElevenLabsTTSCatalog.voices.map { Self.elevenlabs(model, $0) })
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

    // exhaustive provider/model resolution across the existing catalogue; no behavior change.
    // swiftlint:disable:next cyclomatic_complexity
    public static func resolved(
        modelID: String?, voiceID: String?, accountInventory: VoiceAccountInventory?
    ) throws -> Self {
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identifier = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let voice = try elevenLabsSelection(
            model: model, identifier: voiceID?.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return voice
        }
        if let voice = try sonioxSelection(model: model, identifier: voiceID, inventory: accountInventory) {
            return voice
        }
        if let voice = try fixedProviderSelection(model: model, identifier: identifier) {
            return voice
        }
        if let voice = try cartesiaSelection(model: model, identifier: identifier) {
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

    private static func elevenLabsSelection(model: String?, identifier: String?) throws -> Self? {
        guard model == ElevenLabsTTSCatalog.providerIdentifier || model?.hasPrefix("elevenlabs/") == true
            || model?.hasPrefix("eleven_") == true
            || identifier?.lowercased().hasPrefix("elevenlabs/") == true else { return nil }
        let selected: ElevenLabsTTSModels.Model
        if model == nil || model == ElevenLabsTTSCatalog.providerIdentifier {
            selected = ElevenLabsTTSCatalog.defaultModel
        } else {
            guard let model, let found = ElevenLabsTTSModels.model(forID: model) else {
                throw VoiceSynthesisConfigurationError.unsupportedVoice
            }
            selected = found
        }
        // ElevenLabs voice IDs are case-sensitive. Never lowercase an API path.
        guard let identifier, let voice = ElevenLabsTTSCatalog.voice(forID: identifier) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .elevenlabs(selected, voice)
    }

    private static func sonioxSelection(
        model: String?, identifier: String?, inventory: VoiceAccountInventory?
    ) throws -> Self? {
        let scoped = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sonioxModel = model.map { $0.hasPrefix("soniox/") ? String($0.dropFirst(7)) : $0 }
        guard model == "soniox" || model?.hasPrefix("soniox/") == true
            || model?.hasPrefix("tts-rt-") == true
            || sonioxModel.flatMap({ SonioxTTSCatalog.model(forLegacyID: $0) }) != nil
            || scoped?.lowercased().hasPrefix("soniox/") == true else { return nil }
        guard model == nil || model == "soniox"
            || sonioxModel.flatMap({ SonioxTTSCatalog.model(forLegacyID: $0) }) != nil else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        let resolved = SonioxTTSCatalog.resolvedVoice(
            voiceID: scoped, accountVoices: inventory?.soniox?.voices ?? [])
        guard resolved.fallbackReason == nil else { throw VoiceSynthesisConfigurationError.unsupportedVoice }
        return .soniox(resolved)
    }
}
