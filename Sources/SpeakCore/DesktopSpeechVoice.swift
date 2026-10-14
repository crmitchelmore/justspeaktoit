import Foundation

/// Only routes the portable desktop synthesis engine executes, not every voice
/// a provider or another platform can offer.
public enum DesktopSpeechVoice: Hashable, Sendable {
    case deepgram(DeepgramSpeechCatalog.Voice)
    case azureNeural(AzureNeuralVoice)
    case azureMAI(AzureMAIVoice)
    case xai(XAITTSVoice)
    case cartesia(CartesiaTTSVoice)

    public var id: String {
        switch self {
        case .deepgram(let voice): voice.id
        case .azureNeural(let voice): voice.id
        case .azureMAI(let voice): voice.id
        case .xai(let voice): voice.providerVoiceID
        case .cartesia(let voice): voice.providerVoiceID
        }
    }

    public var name: String {
        switch self {
        case .deepgram(let voice): voice.name
        case .azureNeural(let voice): voice.name
        case .azureMAI(let voice): voice.displayName
        case .xai(let voice): voice.displayName
        case .cartesia(let voice): voice.displayName
        }
    }

    public var modelID: String {
        switch self {
        case .deepgram(let voice): voice.model.id
        case .azureNeural: "azure/neural"
        case .azureMAI(let voice): voice.model.rawValue
        case .xai: XAITTSCatalog.providerIdentifier
        case .cartesia: CartesiaTTSCatalog.desktopModelIdentifier
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
        }
    }

    public var apiKeyIdentifier: String {
        switch self {
        case .deepgram: VoiceOutputProvider.deepgram.apiKeyIdentifier
        case .azureNeural, .azureMAI: AzureSpeechConfiguration.credentialIdentifier
        case .xai: XAITTSCatalog.credentialIdentifier
        case .cartesia: CartesiaTTSCatalog.credentialIdentifier
        }
    }

    public var capabilities: VoiceSynthesisCapabilities {
        switch self {
        case .deepgram: .naturalSpeech
        case .azureNeural: .azureNeural
        case .azureMAI: .azureMAI
        case .xai: .xai
        case .cartesia: .cartesia
        }
    }

    public static var voices: [Self] {
        DeepgramSpeechCatalog.voices.map(Self.deepgram) + AzureNeuralVoiceCatalog.voices.map(Self.azureNeural)
            + AzureMAIVoiceCatalog.voices.map(Self.azureMAI)
            + XAITTSCatalog.voices.map(Self.xai)
            + CartesiaTTSCatalog.voices.map(Self.cartesia)
    }

    public static func resolved(
        modelID: String?, voiceID: String?
    ) throws -> Self {
        try resolved(modelID: modelID, voiceID: voiceID, xaiInventory: nil)
    }

    public static func resolved(
        modelID: String?, voiceID: String?, xaiInventory: XAIAccountVoiceInventory?
    ) throws -> Self {
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identifier = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let voice = try cartesiaSelection(model: model, identifier: identifier) {
            return voice
        }
        if let voice = try xaiSelection(model: model, identifier: identifier,
            original: voiceID?.trimmingCharacters(in: .whitespacesAndNewlines), inventory: xaiInventory) {
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

    private static func xaiSelection(
        model: String?, identifier: String?, original: String?, inventory: XAIAccountVoiceInventory?
    ) throws -> Self? {
        guard model == XAITTSCatalog.providerIdentifier || model?.hasPrefix(XAITTSCatalog.voiceIDPrefix) == true
            || identifier?.hasPrefix(XAITTSCatalog.voiceIDPrefix) == true else { return nil }
        guard model == nil || model == XAITTSCatalog.providerIdentifier, let identifier else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        if let voice = XAITTSCatalog.voice(forID: identifier) { return .xai(voice) }
        if let original, let voice = inventory?.voice(forID: original) { return .xai(voice) }
        throw VoiceSynthesisConfigurationError.unsupportedVoice
    }
}
