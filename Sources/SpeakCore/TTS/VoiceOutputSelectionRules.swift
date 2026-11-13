import Foundation

/// Why a saved read aloud model, voice or speed cannot be used with a provider.
/// Each message is nil when that part is valid.
public struct VoiceOutputSelectionProblems: Equatable, Sendable {
    public var model: String?
    public var voice: String?
    public var speed: String?

    public var isEmpty: Bool { model == nil && voice == nil && speed == nil }
}

extension VoiceOutputProvider {
    /// The provider a fresh install uses.
    public static let defaultProvider: VoiceOutputProvider = .inferred(modelID: nil, voiceID: nil)

    /// The model and voice a fresh install stores for the default provider.
    public static let defaultSelection: (model: String, voice: String) = {
        let selection = DeepgramSpeechCatalog.resolvedSelection(modelID: nil, voiceID: nil)
        return (selection.model.id, selection.voice.id)
    }()

    /// Checks a stored selection against the shared catalogues. A valid selection
    /// is exactly what the provider's picker stores, so the iPhone's
    /// voice/model reconciliation leaves it unchanged.
    public func selectionProblems(model: String, voice: String, speed: Double) -> VoiceOutputSelectionProblems {
        var problems = VoiceOutputSelectionProblems()
        switch self {
        case .deepgram: Self.checkDeepgram(model: model, voice: voice, into: &problems)
        case .soniox: Self.checkSoniox(model: model, voice: voice, into: &problems)
        case .openrouter: Self.checkOpenRouter(model: model, voice: voice, into: &problems)
        }
        if !speedRange.contains(speed) {
            problems.speed = "\(displayName) speaks between \(speedRange.lowerBound) and \(speedRange.upperBound)."
        }
        return problems
    }

    private static func checkDeepgram(model: String, voice: String, into problems: inout VoiceOutputSelectionProblems) {
        guard let known = DeepgramSpeechCatalog.models.first(where: { $0.id == model }) else {
            let models = DeepgramSpeechCatalog.models.map(\.id).joined(separator: ", ")
            problems.model = "Not a Deepgram speech model; use one of: \(models)."
            return
        }
        if !DeepgramSpeechCatalog.voices(forModelID: known.id).contains(where: { $0.id == voice }) {
            problems.voice = "\"\(voice)\" is not a \(known.displayName) voice."
        }
    }

    private static func checkSoniox(model: String, voice: String, into problems: inout VoiceOutputSelectionProblems) {
        let models = SonioxTTSCatalog.models.map(\.rawValue)
        if !models.contains(model) {
            problems.model = "Not a Soniox speech model; use one of: \(models.joined(separator: ", "))."
        }
        if let builtIn = SonioxTTSCatalog.voice(forID: voice) {
            if builtIn.providerVoiceID != voice {
                problems.voice = "Use \"\(builtIn.providerVoiceID)\"."
            }
        } else if !isAccountVoice(voice, prefix: "soniox/") {
            problems.voice = "Must be a Soniox voice such as \"soniox/\(SonioxTTSCatalog.defaultVoiceID)\"."
        }
    }

    private static func checkOpenRouter(
        model: String, voice: String, into problems: inout VoiceOutputSelectionProblems
    ) {
        guard let selection = OpenRouterSpeechSelection(id: model) else {
            problems.model = "Not an OpenRouter speech selection; choose one in Browse OpenRouter Audio."
            return
        }
        let expected = selection.voice ?? ""
        if voice != expected {
            problems.voice = "Must match the OpenRouter speech selection's voice: \"\(expected)\"."
        }
    }

    private static func isAccountVoice(_ voice: String, prefix: String) -> Bool {
        guard voice.hasPrefix(prefix), voice.utf8.count <= 512 else { return false }
        let name = voice.dropFirst(prefix.count)
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
