import Foundation

/// Extensible model projection. The original Aura enum remains source compatible.
public enum DeepgramSpeechCatalog {
    public struct Model: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
    }

    public struct Voice: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let model: Model
        public let gender: DeepgramTTSVoiceGender
        public let accent: DeepgramTTSVoiceAccent
        public let style: DeepgramTTSVoiceStyle
        public var providerVoiceID: String { "deepgram/\(id)" }
        public var displayName: String { "\(name) (\(accent.displayName), \(gender.displayName))" }
    }

    public struct Selection: Equatable, Sendable {
        public let model: Model
        public let voice: Voice
    }

    public static let flux = Model(id: "flux", displayName: "Flux (English)")
    public static let models = DeepgramTTSCatalog.models.map {
        Model(id: $0.id, displayName: $0.displayName)
    } + [flux]
    public static let voices = DeepgramTTSCatalog.voices.map(project) + fluxVoices

    /// Featured English voices verified 2026-09-05 against Deepgram's Flux catalogue.
    /// https://developers.deepgram.com/docs/flux-tts/voices
    public static let fluxVoices: [Voice] = [
        fluxVoice("hannah", .female, .american, .clear),
        fluxVoice("kit", .male, .british, .warm),
        fluxVoice("alexis", .female, .american, .professional),
        fluxVoice("cliff", .male, .american, .deep),
        fluxVoice("sienna", .female, .american, .warm),
        fluxVoice("cole", .male, .american, .energetic),
        fluxVoice("brooke", .female, .american, .energetic),
        fluxVoice("colin", .male, .british, .warm),
        fluxVoice("gemma", .female, .british, .warm),
        fluxVoice("haley", .female, .american, .professional),
        fluxVoice("heather", .female, .american, .energetic),
        fluxVoice("miles", .male, .american, .professional),
        fluxVoice("sean", .male, .british, .warm)
    ]

    public static func voices(forModelID modelID: String) -> [Voice] {
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == flux.id {
            return fluxVoices
        }
        return DeepgramTTSCatalog.voices(forModelID: modelID).map(project)
    }

    public static func resolvedSelection(modelID: String?, voiceID: String?) -> Selection {
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var voice = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if voice.hasPrefix("deepgram/") { voice.removeFirst("deepgram/".count) }
        let exact = fluxVoices.first { $0.id == voice }
        if model == flux.id || (DeepgramTTSCatalog.model(forLegacyID: model) == nil && exact != nil) {
            let selected = exact ?? fluxVoices.first { $0.id == "flux-kit-en" }!
            return Selection(model: flux, voice: selected)
        }
        let legacy = DeepgramTTSCatalog.resolvedSelection(modelID: modelID, voiceID: voiceID)
        let selected = project(legacy.voice)
        return Selection(model: selected.model, voice: selected)
    }

    private static func project(_ voice: DeepgramTTSVoice) -> Voice {
        Voice(id: voice.id, name: voice.name,
              model: Model(id: voice.model.id, displayName: voice.model.displayName),
              gender: voice.gender, accent: voice.accent, style: voice.style)
    }

    private static func fluxVoice(
        _ name: String, _ gender: DeepgramTTSVoiceGender,
        _ accent: DeepgramTTSVoiceAccent, _ style: DeepgramTTSVoiceStyle
    ) -> Voice {
        Voice(id: "flux-\(name)-en", name: name.capitalized, model: flux,
              gender: gender, accent: accent, style: style)
    }
}
