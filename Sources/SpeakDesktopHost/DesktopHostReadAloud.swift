import Foundation
import SpeakCore
import SpeakDesktop

/// The voice Read aloud uses, persisted as catalogue identifiers so a retired
/// or unknown voice resolves through the canonical catalogue's migrations.
package struct DesktopVoiceOutputSettings: Codable, Equatable, Sendable {
    package var modelID: String?
    package var voiceID: String?
    package var strictVoiceSelection: Bool?
    package var autoPlay: Bool?
    package var saveToRecordings: Bool?
    package var speed: Double?
    package var pitch: Double?
    package var useSSML: Bool?
    package var trackUsage: Bool?
    package var favoriteVoices: [String]?
    package var sonioxRegion: String?
    package var language: String?
    package var quality: String?
    package var format: String?

    private enum CodingKeys: String, CodingKey {
        case modelID, voiceID, strictVoiceSelection
        case autoPlay = "ttsAutoPlay"
        case saveToRecordings = "ttsSaveToDirectory"
        case speed = "ttsSpeed"
        case pitch = "ttsPitch"
        case useSSML = "ttsUseSSML"
        case trackUsage = "ttsTrackUsage"
        case favoriteVoices = "ttsFavoriteVoices"
        case sonioxRegion = "sonioxTTSRegion"
        case language = "ttsLanguage"
        case quality = "ttsQuality"
        case format = "ttsOutputFormat"
    }

    package var generationOptions: VoiceGenerationOptions {
        .init(autoPlay: autoPlay ?? SpeechGenerationDefaults.autoPlay,
              saveToRecordings: saveToRecordings ?? SpeechGenerationDefaults.saveToRecordings)
    }

    package var voice: DeepgramSpeechCatalog.Voice {
        DeepgramSpeechCatalog.resolvedSelection(modelID: modelID, voiceID: voiceID).voice
    }

    package func synthesisSelection() throws -> DesktopSpeechSelection {
        try synthesisSelection(inventory: nil)
    }

    package func synthesisSelection(inventory: XAIAccountVoiceInventory?) throws -> DesktopSpeechSelection {
        try synthesisSelection(accountInventory: inventory.map(VoiceAccountInventory.xai))
    }

    package func synthesisSelection(accountInventory: VoiceAccountInventory?) throws -> DesktopSpeechSelection {
        let voice = try resolvedVoice(accountInventory: accountInventory)
        let region: SonioxTTSRegion
        if case .soniox = voice {
            region = try validatedSonioxRegion()
            try SonioxVoicePreference.validateLanguage(language)
        } else { region = .unitedStates }
        return try .init(
            voice: voice,
            options: validatedSynthesisOptions(), accountInventory: accountInventory,
            sonioxRegion: region, language: language
        )
    }

    package func resolvedVoice(accountInventory: VoiceAccountInventory?) throws -> DesktopSpeechVoice {
        try storedVoice(accountInventory: accountInventory)
            .applyingQuality(VoiceSynthesisQuality.storedValue(quality))
    }

    package func validatedSonioxRegion() throws -> SonioxTTSRegion {
        guard let region = SonioxTTSRegion.recognized(from: sonioxRegion) else {
            throw DesktopSonioxSpeechError.unsupportedRegion
        }
        return region
    }

    package var pickerPresentation: (labels: [String], selected: Int) {
        pickerPresentation(inventory: nil)
    }

    package func pickerPresentation(inventory: XAIAccountVoiceInventory?) -> (labels: [String], selected: Int) {
        pickerPresentation(accountInventory: inventory.map(VoiceAccountInventory.xai))
    }

    package func pickerPresentation(accountInventory: VoiceAccountInventory?) -> (labels: [String], selected: Int) {
        var labels = DesktopSpeechVoice.voices.map(\.label)
        do {
            let voice = try resolvedVoice(accountInventory: accountInventory)
            if let selected = DesktopSpeechVoice.voices.firstIndex(of: voice) { return (labels, selected) }
            labels.append(String(voice.label.prefix(220)))
            return (labels, labels.count - 1)
        } catch {
            labels.append("Unavailable stored voice — choose an executable voice")
            return (labels, labels.count - 1)
        }
    }

    package var controlsPresentation: DesktopVoiceControlsPresentation {
        controlsPresentation(inventory: nil)
    }

    package func controlsPresentation(inventory: XAIAccountVoiceInventory?) -> DesktopVoiceControlsPresentation {
        controlsPresentation(accountInventory: inventory.map(VoiceAccountInventory.xai))
    }

    package func controlsPresentation(accountInventory: VoiceAccountInventory?) -> DesktopVoiceControlsPresentation {
        do {
            let voice = try resolvedVoice(accountInventory: accountInventory)
            return .init(speed: speed ?? VoiceSynthesisOptions.defaultSpeed,
                         pitch: pitch ?? VoiceSynthesisOptions.defaultPitch, ssml: useSSML == true ? 1 : 0,
                         capabilities: voice.capabilities.nativeFlags, label: voice.label,
                         minimumSpeed: voice.capabilities.speedRange.lowerBound,
                         maximumSpeed: voice.capabilities.speedRange.upperBound, guidance: voice.deliveryGuidance)
        } catch {
            return .init(speed: speed ?? VoiceSynthesisOptions.defaultSpeed,
                         pitch: pitch ?? VoiceSynthesisOptions.defaultPitch,
                         ssml: useSSML == true ? 1 : 0, capabilities: 0,
                         label: "Stored voice unavailable. Choices are retained; select a compatible voice.",
                         minimumSpeed: VoiceSynthesisOptions.speedRange.lowerBound,
                         maximumSpeed: VoiceSynthesisOptions.speedRange.upperBound,
                         guidance: "The stored voice or quality is unavailable. Choose a compatible voice and quality.")
        }
    }

    package init(modelID: String? = nil, voiceID: String? = nil) {
        self.modelID = modelID
        self.voiceID = voiceID
    }

    package init(voice: DeepgramSpeechCatalog.Voice) {
        self.init(modelID: voice.model.id, voiceID: voice.id)
    }

    package init(voice: DesktopSpeechVoice) {
        self.init(modelID: voice.modelID, voiceID: voice.id)
    }

    /// Picker order: the canonical catalogue, never a host-owned copy.
    package static var voices: [DeepgramSpeechCatalog.Voice] { DeepgramSpeechCatalog.voices }
    package static func label(_ voice: DeepgramSpeechCatalog.Voice) -> String {
        "\(voice.displayName) — \(voice.model.displayName)"
    }
}

package struct DesktopVoiceControlsPresentation: Sendable {
    package let speed: Double
    package let pitch: Double
    package let ssml: Int32
    package let capabilities: Int32
    package let label: String
    package let minimumSpeed: Double
    package let maximumSpeed: Double
    package let guidance: String
    package var markupHelperEnabled: Bool { capabilities & 4 != 0 && ssml == 1 }
}

/// History playback that can also speak a record's Read aloud as consecutive
/// segments. A speech keeps its record the one audible owner from the click to
/// its last segment, so Play/Pause and Stop act on it while segments are
/// synthesized and between them.
package protocol DesktopHostSpeechPlayback: DesktopHostPlayback {
    associatedtype Speech: Sendable
    /// Stops the current playback and shows `recordID` as speaking until
    /// `endSpeech`, or until Stop, another row, recording, import, History
    /// playback, another speech or close ends it.
    func beginSpeech(recordID: UUID) throws -> Speech
    /// Plays one synthesized segment and returns the seconds rendered. A
    /// segment of an ended speech is refused with `CancellationError`, as is
    /// one interrupted by Stop or by cancelling the calling task.
    func playToCompletion(_ speech: Speech, path: String) async throws -> TimeInterval
    /// Ends `speech`; a speech already ended or replaced is left alone.
    func endSpeech(_ speech: Speech)
}

/// A host's Deepgram voice output: the shared engine behind the host's own
/// private staging for synthesized audio.
package protocol DesktopHostVoiceOutput: Sendable {
    /// Synthesizes `request` and plays it through `play`, which must stop when
    /// its task is cancelled; see `DeepgramVoiceOutput.speak`.
    func speak(
        _ request: DeepgramSpeechRequest,
        credential: @Sendable () async throws -> String,
        through play: @escaping @Sendable (URL) async throws -> TimeInterval
    ) async throws -> DeepgramVoiceOutput.Outcome
}

/// The controller's Read aloud state. The engine and its private folder are
/// created on first use, never at launch. Which Read aloud may still report
/// is decided by the controller's shared `playbackRequests`.
package struct DesktopHostReadAloudState<Speech: Sendable, Engine: DesktopHostVoiceOutput>: Sendable {
    package var task: Task<Void, Never>?
    package var exportTask: Task<Void, Never>?
    package var formatSaveTask: Task<Void, Never>?
    package var codecOperationID: UUID?
    /// Keeps the record's playback controls active, so Pause and Stop work
    /// while segments are synthesized and between them.
    package var speech: Speech?
    package private(set) var engine: Engine?

    package init() {}

    /// The engine, created by `make` the first time; nil while it cannot be.
    package mutating func output(_ make: () throws -> Engine) -> Engine? {
        if engine == nil { engine = try? make() }
        return engine
    }
}

/// Read aloud speaks the displayed transcript of the selected record through
/// the shared playback, so speech and History playback are never audible
/// together and share Play/Pause, Stop and the recording lockout. Long
/// transcripts are spoken as consecutive segments within Deepgram's limit.
extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func voiceOutputSettings() -> DesktopVoiceOutputSettings { settings.voiceOutput ?? .init() }

    package func saveVoiceOutput(_ voiceOutput: DesktopVoiceOutputSettings) {
        let label = (try? voiceOutput.storedVoice(accountInventory: selectedVoiceAccountInventory))?.label
        _ = persistVoiceOutput(voiceOutput, message: label.map { "Read aloud voice saved: \($0)." } ??
            "Voice Output settings saved. The stored voice is unavailable on this host.")
    }

    package func selectVoiceOutput(_ voice: DeepgramSpeechCatalog.Voice) {
        selectVoiceOutput(.deepgram(voice))
    }

    package func selectVoiceOutput(_ voice: DesktopSpeechVoice) {
        var changed = voiceOutputSettings()
        changed.modelID = voice.modelID
        changed.voiceID = voice.id
        changed.strictVoiceSelection = nil
        if case .openai = voice { changed.quality = voice.defaultQuality.rawValue }
        if case .elevenlabs = voice { changed.quality = voice.defaultQuality.rawValue }
        saveVoiceOutput(changed)
    }

    @discardableResult
    package func saveVoiceSynthesisOptions(_ options: VoiceSynthesisOptions) -> Bool {
        var changed = voiceOutputSettings()
        changed.speed = options.speed
        changed.pitch = options.pitch
        changed.useSSML = options.useSSML
        if let quality = options.quality { changed.quality = quality.rawValue }
        return persistVoiceOutput(changed, message: "Voice synthesis controls saved.")
    }

    @discardableResult
    package func saveVoiceGenerationOptions(_ options: VoiceGenerationOptions) -> Bool {
        var changed = voiceOutputSettings()
        changed.autoPlay = options.autoPlay
        changed.saveToRecordings = options.saveToRecordings
        return persistVoiceOutput(changed, message: "Generated voice playback and save preferences saved.")
    }

    package func persistVoiceOutput(_ voiceOutput: DesktopVoiceOutputSettings, message: String) -> Bool {
        guard !closed else { return false }
        let previous = voiceOutputSettings()
        let wasTracking = voiceUsageTrackingEnabled
        var changed = settings
        changed.voiceOutput = voiceOutput
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            voiceSettingsRevision &+= 1
            reconcileSonioxRegionChange(previous)
            if previous.modelID != voiceOutput.modelID || previous.voiceID != voiceOutput.voiceID
                || previous.quality != voiceOutput.quality
                || previous.strictVoiceSelection != voiceOutput.strictVoiceSelection {
                voiceCredentialEpoch = UUID()
            }
            if wasTracking != voiceUsageTrackingEnabled { voiceUsage.epoch = UUID() }
            if !busy, recording == nil { update(message) }
            return true
        } catch { update("Could not save Voice Output settings: \(error.localizedDescription)"); return false }
    }

    /// `text` is the transcript displayed for `identifier` when Read aloud was clicked.
    package func readAloud(_ identifier: String, text: String) async {
        guard !closed, canUseHistory, let id = UUID(uuidString: identifier), history[id] != nil,
              selectedHistoryID == id, isVisible(id) else { return }
        guard !SpeechTextSegmenter.segments(text).isEmpty else {
            update("There is no transcript to read aloud."); return
        }
        startVoiceRead(text: text, source: .history, owner: id, recordID: id)
    }

    package func readVoiceSource(_ snapshot: VoiceOutputSourceSnapshot) async {
        if let id = snapshot.recordID { await readAloud(id.uuidString, text: snapshot.text); return }
        guard !closed, canUseHistory else { return }
        startVoiceRead(text: snapshot.text, source: snapshot.source, owner: UUID(), recordID: nil)
    }

}
