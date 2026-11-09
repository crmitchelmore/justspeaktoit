import Foundation

/// One voice an app can speak with, as `list_voices` reports it and
/// `speak_text` chooses among them. Hosts list only voices they can use now:
/// a cloud voice appears once its provider's key is saved in the app.
public struct AutomationVoice: Codable, Sendable, Equatable {
    /// The identifier `speak_text` accepts as `voice`.
    public var id: String
    public var name: String
    /// Stable provider identifier, e.g. `openai`, and its display name.
    public var provider: String
    public var providerName: String
    /// Selectable models; empty when the provider offers no choice.
    public var models: [String]
    /// The model used when none is asked for.
    public var model: String?
    /// The app's current voice. Only one entry is selected.
    public var selected: Bool
    /// Saved as a favourite in the app.
    public var favorite: Bool
    /// Runs on this device with no key or network.
    public var onDevice: Bool

    public init(
        id: String, name: String, provider: String, providerName: String, models: [String] = [],
        model: String? = nil, selected: Bool = false, favorite: Bool = false, onDevice: Bool = false
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.providerName = providerName
        self.models = models
        self.model = model
        self.selected = selected
        self.favorite = favorite
        self.onDevice = onDevice
    }
}

/// The voice and model a selection resolves to.
public struct AutomationVoiceChoice: Equatable, Sendable {
    public let voice: AutomationVoice
    public let model: String?
    /// Nothing usable was configured, so the on-device voice stands in.
    public let isFallback: Bool
}

/// Chooses one voice from a host's list, the same way on every platform.
///
/// Matching is case-insensitive. An ID wins over a display name, and a name
/// shared by several voices is refused rather than guessed.
public enum AutomationVoiceResolver {
    public static func resolve(
        _ selection: AutomationSpeechSelection, in voices: [AutomationVoice]
    ) throws -> AutomationVoiceChoice {
        var candidates = voices
        if let provider = selection.provider {
            candidates = candidates.filter { matches($0.provider, provider) || matches($0.providerName, provider) }
            guard !candidates.isEmpty else {
                throw notFound("No usable voices from provider \"\(provider)\". Save its key in the app.")
            }
        }
        if let favorite = selection.favorite {
            candidates = try self.named(favorite, in: candidates.filter(\.favorite), kind: "favourite voice")
        }
        if selection.wantsOnDevice {
            candidates = candidates.filter(\.onDevice)
            guard !candidates.isEmpty else {
                throw AutomationError(
                    code: .unsupportedCommand,
                    message: "This app has no on-device voice. Pass a voice from `speak voices`."
                )
            }
        } else if let voice = selection.voice {
            candidates = try self.named(voice, in: candidates, kind: "voice")
        }
        let isDefault = selection.voice == nil && selection.provider == nil && selection.favorite == nil
        let fallback = isDefault && !candidates.contains(where: \.selected)
        let chosen = isDefault
            ? candidates.first(where: \.selected) ?? candidates.first(where: \.onDevice)
            : candidates.first(where: \.selected) ?? candidates.first(where: \.favorite) ?? candidates.first
        guard let chosen else {
            throw AutomationError(
                code: .unsupportedCommand,
                message: "No voice is configured in Just Speak To It, and this platform has no on-device voice. "
                    + "Choose a voice and save its key in the app's Voice settings, or pass --voice."
            )
        }
        return AutomationVoiceChoice(voice: chosen, model: try self.model(selection.model, for: chosen),
                                     isFallback: fallback)
    }

    private static func named(_ query: String, in voices: [AutomationVoice], kind: String) throws -> [AutomationVoice] {
        let byID = voices.filter { matches($0.id, query) }
        if !byID.isEmpty { return byID }
        let byName = voices.filter { matches($0.name, query) }
        guard !byName.isEmpty else {
            throw notFound("No usable \(kind) matches \"\(query)\". Run `speak voices` to list them.")
        }
        let distinct = Set(byName.map(\.id))
        guard distinct.count == 1 else {
            let examples = distinct.sorted().prefix(5).joined(separator: ", ")
            throw AutomationError(
                code: .invalidArgument, message: "\"\(query)\" names several voices (\(examples)). Pass an ID."
            )
        }
        return byName
    }

    private static func model(_ requested: String?, for voice: AutomationVoice) throws -> String? {
        guard let requested else { return voice.model }
        if let model = voice.models.first(where: { matches($0, requested) || matches(shortName($0), requested) }) {
            return model
        }
        let options = voice.models.isEmpty ? "it has no model choice" : "choose " + voice.models.joined(separator: ", ")
        throw AutomationError(
            code: .invalidArgument, message: "\(voice.name) cannot use model \"\(requested)\"; \(options)."
        )
    }

    private static func shortName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    private static func matches(_ value: String, _ query: String) -> Bool {
        value.compare(query, options: [.caseInsensitive]) == .orderedSame
    }

    private static func notFound(_ message: String) -> AutomationError {
        AutomationError(code: .invalidArgument, message: message)
    }
}

extension DesktopSpeechVoice {
    /// The provider in the Mac's speech-provider vocabulary, so `--provider`
    /// names the same provider on every platform.
    public var automationProvider: (id: String, name: String) {
        switch self {
        case .deepgram: ("deepgram", "Deepgram")
        case .azureNeural, .azureMAI: ("azure", "Azure Speech")
        case .xai: ("xai", "xAI")
        case .cartesia: ("cartesia", "Cartesia Sonic")
        case .mistral: ("mistral", "Mistral Voxtral")
        case .soniox: ("soniox", "Soniox")
        case .gemini: ("google", GeminiTranscribeModels.providerDisplayName)
        case .groq: ("groq", "Groq Orpheus")
        case .speechmatics: ("speechmatics", "Speechmatics")
        case .openai, .openaiRealtime: ("openai", "OpenAI")
        case .elevenlabs: ("elevenlabs", "ElevenLabs")
        }
    }
}
