#if os(iOS)
import Foundation
import SpeakCore
import SwiftUI

/// Generic voice-output selections retain legacy `openclaw.*` preference keys for compatibility.
/// No gateway token or conversation preference is loaded, migrated or deleted.
@MainActor
final class IOSVoiceOutputSettings: ObservableObject {
    static let shared = IOSVoiceOutputSettings(defaults: .standard)
    static let sonioxBuiltInVoices = SonioxTTSCatalog.voices

    let defaults: UserDefaults

    @Published var ttsProvider: VoiceOutputProvider {
        didSet { defaults.set(ttsProvider.rawValue, forKey: "openclaw.ttsProvider") }
    }

    @Published var ttsVoice: String {
        didSet { defaults.set(ttsVoice, forKey: "openclaw.ttsVoice") }
    }

    @Published var ttsVoiceName: String {
        didSet { defaults.set(ttsVoiceName, forKey: "openclaw.ttsVoiceName") }
    }

    @Published var ttsModel: String {
        didSet { defaults.set(ttsModel, forKey: "openclaw.ttsModel") }
    }

    @Published var ttsSpeed: Double {
        didSet { defaults.set(ttsSpeed, forKey: "openclaw.ttsSpeed") }
    }

    @Published var ttsLanguageIdentifier: String {
        didSet { defaults.set(ttsLanguageIdentifier, forKey: "openclaw.ttsLanguage") }
    }

    @Published var sonioxRegion: SonioxTTSRegion {
        didSet { defaults.set(sonioxRegion.rawValue, forKey: "openclaw.sonioxRegion") }
    }

    /// Migrates legacy selections and keeps the selected voice compatible with its model.
    func validateVoiceModelCombination() {
        switch ttsProvider {
        case .deepgram:
            let incompatibleVoice = ttsVoice.hasPrefix("soniox/") ? nil : ttsVoice
            let selection = DeepgramSpeechCatalog.resolvedSelection(modelID: ttsModel, voiceID: incompatibleVoice)
            if ttsModel != selection.model.id { ttsModel = selection.model.id }
            if ttsVoice != selection.voice.id { ttsVoice = selection.voice.id }
            ttsVoiceName = selection.voice.displayName
        case .openrouter:
            // Preserve dynamic selections, including retired IDs, for explicit errors and reselection.
            break
        case .soniox:
            ttsModel = SonioxTTSCatalog.defaultModel.rawValue
            if let voice = SonioxTTSCatalog.voice(forID: ttsVoice) {
                ttsVoice = voice.providerVoiceID
                ttsVoiceName = voice.displayName
            } else if !ttsVoice.hasPrefix("soniox/") {
                let voice = SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel)
                ttsVoice = voice.providerVoiceID
                ttsVoiceName = voice.displayName
            }
        }
        ttsSpeed = min(max(ttsSpeed, ttsProvider.speedRange.lowerBound), ttsProvider.speedRange.upperBound)
    }

    /// Names the selected voice after the raw configuration changes the selection.
    func refreshVoiceName() {
        switch ttsProvider {
        case .deepgram:
            ttsVoiceName = DeepgramSpeechCatalog.voices(forModelID: ttsModel)
                .first { $0.id == ttsVoice }?.displayName ?? ttsVoice
        case .soniox:
            ttsVoiceName = SonioxTTSCatalog.voice(forID: ttsVoice)?.displayName
                ?? String(ttsVoice.dropFirst("soniox/".count))
        case .openrouter:
            ttsVoiceName = ttsVoice.isEmpty ? "Provider default" : ttsVoice
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let storedModel = defaults.string(forKey: "openclaw.ttsModel")
        let storedVoice = defaults.string(forKey: "openclaw.ttsVoice")
        let resolvedProvider = VoiceOutputProvider(
            rawValue: defaults.string(forKey: "openclaw.ttsProvider") ?? ""
        ) ?? VoiceOutputProvider.inferred(modelID: storedModel, voiceID: storedVoice)
        let (resolvedModel, resolvedVoice) = Self.restoredVoiceSelection(
            provider: resolvedProvider, model: storedModel, voice: storedVoice
        )
        self.ttsProvider = resolvedProvider
        self.ttsVoice = resolvedVoice
        self.ttsVoiceName = defaults.string(forKey: "openclaw.ttsVoiceName") ?? resolvedVoice
        self.ttsModel = resolvedModel
        self.ttsSpeed = defaults.object(forKey: "openclaw.ttsSpeed") as? Double ?? 1.0
        self.ttsLanguageIdentifier = VoiceOutputLanguageCatalog.normalizedIdentifier(
            defaults.string(forKey: "openclaw.ttsLanguage")
        )
        self.sonioxRegion = SonioxTTSRegion.migrated(
            from: defaults.string(forKey: "openclaw.sonioxRegion")
        )
        defaults.set(ttsVoice, forKey: "openclaw.ttsVoice")
        defaults.set(ttsModel, forKey: "openclaw.ttsModel")
        defaults.set(ttsProvider.rawValue, forKey: "openclaw.ttsProvider")
    }

    private static func restoredVoiceSelection(
        provider: VoiceOutputProvider, model: String?, voice: String?
    ) -> (model: String, voice: String) {
        switch provider {
        case .soniox:
            let storedVoice = voice.flatMap { $0.hasPrefix("soniox/") ? $0 : nil }
            return (
                SonioxTTSCatalog.defaultModel.rawValue,
                storedVoice ?? SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel).providerVoiceID
            )
        case .openrouter:
            return (model ?? "", voice ?? "")
        case .deepgram:
            let selection = DeepgramSpeechCatalog.resolvedSelection(modelID: model, voiceID: voice)
            return (selection.model.id, selection.voice.id)
        }
    }

}
#endif
