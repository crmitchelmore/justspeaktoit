import Foundation

extension DesktopSpeechVoice {
    static func fixedProviderSelection(model: String?, identifier: String?) throws -> Self? {
        try openaiSelection(model: model, identifier: identifier)
            ?? speechmaticsSelection(model: model, identifier: identifier)
            ?? groqSelection(model: model, identifier: identifier)
            ?? geminiSelection(model: model, identifier: identifier)
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
        let selected: GeminiTTSModel
        if model == nil || model == GeminiTTSCatalog.providerIdentifier {
            selected = GeminiTTSCatalog.defaultModel
        } else {
            guard let model, let found = GeminiTTSCatalog.model(forID: model) else {
                throw VoiceSynthesisConfigurationError.unsupportedVoice
            }
            selected = found
        }
        guard let identifier, let voice = GeminiTTSCatalog.voice(forID: identifier) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .gemini(voice, model: selected)
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
}
