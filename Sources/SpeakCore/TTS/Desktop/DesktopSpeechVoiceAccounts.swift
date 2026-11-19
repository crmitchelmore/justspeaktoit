import Foundation

extension DesktopSpeechVoice {
    static func accountSelection(
        model: String?, identifier: String?, original: String?, inventory: VoiceAccountInventory?
    ) throws -> Self? {
        try mistralSelection(model: model, identifier: identifier, inventory: inventory?.mistral)
            ?? xaiSelection(model: model, identifier: identifier, original: original, inventory: inventory?.xai)
    }

    private static func mistralSelection(
        model: String?, identifier: String?, inventory: MistralAccountVoiceInventory?
    ) throws -> Self? {
        guard model?.hasPrefix(MistralTTSCatalog.voiceIDPrefix) == true || model == VoiceAccountProvider.mistral.id
            || model?.hasPrefix("voxtral-") == true
            || identifier?.hasPrefix(MistralTTSCatalog.voiceIDPrefix) == true else { return nil }
        guard model == nil || model == VoiceAccountProvider.mistral.id
            || model == MistralTTSCatalog.defaultModel.rawValue
            || model == MistralTTSCatalog.defaultModel.desktopModelIdentifier,
            let identifier, let voice = inventory?.voice(forID: identifier) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .mistral(voice)
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
