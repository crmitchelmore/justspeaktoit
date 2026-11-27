import Foundation

extension DesktopSpeechVoice {
    static func accountSelection(
        model: String?, identifier: String?, original: String?, inventory: VoiceAccountInventory?
    ) throws -> Self? {
        try mistralSelection(model: model, identifier: identifier, inventory: inventory?.mistral)
            ?? xaiSelection(model: model, identifier: identifier, original: original, inventory: inventory?.xai)
            ?? studioSelection(model: model, identifier: identifier, original: original, inventory: inventory?.studio)
    }

    private static func studioSelection(
        model: String?, identifier: String?, original: String?, inventory: VoiceStudioVoiceInventory?
    ) throws -> Self? {
        guard let kind = try resolvedStudioKind(model: model, identifier: identifier, original: original) else {
            return nil
        }
        let candidate = (original ?? identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return try matchStudioVoice(candidate: candidate, kind: kind, inventory: inventory)
    }

    private static func resolvedStudioKind(
        model: String?, identifier: String?, original: String?
    ) throws -> VoiceStudioKind? {
        let modelKind = model.flatMap(VoiceStudioKind.from(rawOrSlug:))
        let idKind = (original ?? identifier).flatMap(VoiceStudioVoice.kind(forCanonicalID:))
        if model?.hasPrefix("studio/") == true, modelKind == nil {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        if (original ?? identifier)?.lowercased().hasPrefix("studio/") == true, idKind == nil {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        guard let kind = modelKind ?? idKind else { return nil }
        if let modelKind, let idKind, modelKind != idKind {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return kind
    }

    private static func matchStudioVoice(
        candidate: String, kind: VoiceStudioKind, inventory: VoiceStudioVoiceInventory?
    ) throws -> Self {
        if let inventory, inventory.kind == kind {
            let lowered = candidate.lowercased()
            let match = inventory.voices.first { $0.id == candidate || $0.remoteVoiceID == candidate }
                ?? inventory.voices.first {
                    $0.id.lowercased() == lowered || $0.remoteVoiceID.lowercased() == lowered
                }
            guard let match else { throw VoiceSynthesisConfigurationError.unsupportedVoice }
            return .studio(match)
        }
        if kind == .gptSoVITS {
            let lowered = candidate.lowercased()
            let refID = VoiceStudioVoice.gptSoVITSReferenceVoiceID
            let allowed = [refID, "\(VoiceStudioKind.gptSoVITS.rawValue)/\(refID)", VoiceStudioKind.gptSoVITS.rawValue]
            guard lowered.isEmpty || allowed.contains(lowered) else {
                throw VoiceSynthesisConfigurationError.unsupportedVoice
            }
            return .studio(VoiceStudioVoice.gptSoVITSDefaultVoice())
        }
        if let extracted = VoiceStudioVoice.remoteVoiceID(fromCanonicalID: candidate, kind: kind) {
            return .studio(VoiceStudioVoice(studioKind: kind, remoteVoiceID: extracted, name: extracted))
        }
        guard !candidate.isEmpty, !candidate.contains("/") else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .studio(VoiceStudioVoice(studioKind: kind, remoteVoiceID: candidate, name: candidate))
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
