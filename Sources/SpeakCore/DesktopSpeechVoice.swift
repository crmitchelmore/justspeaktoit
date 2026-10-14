import Foundation

/// Only routes the portable desktop synthesis engine executes, not every voice
/// a provider or another platform can offer.
public enum DesktopSpeechVoice: Hashable, Sendable {
    case deepgram(DeepgramSpeechCatalog.Voice)
    case azureNeural(AzureNeuralVoice)

    public var id: String {
        switch self {
        case .deepgram(let voice): voice.id
        case .azureNeural(let voice): voice.id
        }
    }

    public var name: String {
        switch self {
        case .deepgram(let voice): voice.name
        case .azureNeural(let voice): voice.name
        }
    }

    public var modelID: String {
        switch self {
        case .deepgram(let voice): voice.model.id
        case .azureNeural: "azure/neural"
        }
    }

    public var label: String {
        switch self {
        case .deepgram(let voice): "\(voice.displayName) — \(voice.model.displayName)"
        case .azureNeural(let voice): "\(voice.name) — Azure Speech (\(voice.shortName))"
        }
    }

    public var apiKeyIdentifier: String {
        switch self {
        case .deepgram: VoiceOutputProvider.deepgram.apiKeyIdentifier
        case .azureNeural: AzureSpeechConfiguration.credentialIdentifier
        }
    }

    public var capabilities: VoiceSynthesisCapabilities {
        switch self {
        case .deepgram: .naturalSpeech
        case .azureNeural: .azureNeural
        }
    }

    public static var voices: [Self] {
        DeepgramSpeechCatalog.voices.map(Self.deepgram) + AzureNeuralVoiceCatalog.voices.map(Self.azureNeural)
    }

    public static func resolved(modelID: String?, voiceID: String?) throws -> Self {
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identifier = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if model?.hasPrefix("azure/") == true || identifier?.hasPrefix("azure/") == true {
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
}
