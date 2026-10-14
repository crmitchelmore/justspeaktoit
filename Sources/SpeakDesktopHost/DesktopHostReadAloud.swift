import Foundation
import SpeakCore
import SpeakDesktop

/// The voice Read aloud uses, persisted as catalogue identifiers so a retired
/// or unknown voice resolves through the canonical catalogue's migrations.
package struct DesktopVoiceOutputSettings: Codable, Equatable, Sendable {
    package var modelID: String?
    package var voiceID: String?
    package var autoPlay: Bool?
    package var saveToRecordings: Bool?
    package var speed: Double?
    package var pitch: Double?
    package var useSSML: Bool?

    private enum CodingKeys: String, CodingKey {
        case modelID, voiceID
        case autoPlay = "ttsAutoPlay"
        case saveToRecordings = "ttsSaveToDirectory"
        case speed = "ttsSpeed"
        case pitch = "ttsPitch"
        case useSSML = "ttsUseSSML"
    }

    package var generationOptions: VoiceGenerationOptions {
        .init(autoPlay: autoPlay ?? SpeechGenerationDefaults.autoPlay,
              saveToRecordings: saveToRecordings ?? SpeechGenerationDefaults.saveToRecordings)
    }

    package var voice: DeepgramSpeechCatalog.Voice {
        DeepgramSpeechCatalog.resolvedSelection(modelID: modelID, voiceID: voiceID).voice
    }

    package func synthesisSelection() throws -> DesktopSpeechSelection {
        try .init(
            voice: DesktopSpeechVoice.resolved(modelID: modelID, voiceID: voiceID),
            options: VoiceSynthesisOptions(
                speed: speed ?? VoiceSynthesisOptions.defaultSpeed,
                pitch: pitch ?? VoiceSynthesisOptions.defaultPitch,
                useSSML: useSSML ?? VoiceSynthesisOptions.defaultUseSSML
            )
        )
    }

    package var pickerPresentation: (labels: [String], selected: Int) {
        var labels = DesktopSpeechVoice.voices.map(\.label)
        do {
            let voice = try DesktopSpeechVoice.resolved(modelID: modelID, voiceID: voiceID)
            if let selected = DesktopSpeechVoice.voices.firstIndex(of: voice) { return (labels, selected) }
        } catch {
            labels.append("Unavailable stored voice — choose an executable voice")
            return (labels, labels.count - 1)
        }
        labels.append("Unavailable stored voice — choose an executable voice")
        return (labels, labels.count - 1)
    }

    package var controlsPresentation: DesktopVoiceControlsPresentation {
        do {
            let voice = try DesktopSpeechVoice.resolved(modelID: modelID, voiceID: voiceID)
            return .init(speed: speed ?? VoiceSynthesisOptions.defaultSpeed,
                         pitch: pitch ?? VoiceSynthesisOptions.defaultPitch, ssml: useSSML == true ? 1 : 0,
                         capabilities: voice.capabilities.nativeFlags, label: voice.label)
        } catch {
            return .init(speed: speed ?? VoiceSynthesisOptions.defaultSpeed,
                         pitch: pitch ?? VoiceSynthesisOptions.defaultPitch,
                         ssml: useSSML == true ? 1 : 0, capabilities: 0,
                         label: "Stored voice unavailable. Choices are retained; select a compatible voice.")
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

/// A host that reads History transcripts aloud with a canonical Deepgram voice
/// through its own playback, sharing one controller implementation.
package protocol DesktopHostReadAloudPlatform: DesktopHostPlatform
where Playback: DesktopHostSpeechPlayback, VoiceOutputSettings == DesktopVoiceOutputSettings,
      ReadAloudState == DesktopHostReadAloudState<Playback.Speech, VoiceOutput> {
    associatedtype VoiceOutput: DesktopHostVoiceOutput
    /// The engine, staging synthesized audio in `directory`, which it creates
    /// readable only by the current user.
    static func makeVoiceOutput(stagingDirectory directory: URL) throws -> VoiceOutput
    static func synthesizeVoiceOutput(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data
    /// Where this window saves the Deepgram key, e.g. "choose a Deepgram
    /// model, then Save key", for the missing-key status line.
    static var deepgramKeyHint: String { get }
}

package extension DesktopHostReadAloudPlatform {
    static func makeReadAloudState() -> ReadAloudState { ReadAloudState() }

    static func synthesizeVoiceOutput(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try await DesktopSpeechSynthesis().synthesize(
            source, voice: selection.voice, options: selection.options, credential: credential
        )
    }

    /// Cancels the segment being synthesized, so no later one is admitted, and
    /// returns the record's controls to idle once nothing more will be spoken.
    static func stopReadAloud(_ state: inout ReadAloudState, playback: Playback) {
        state.task?.cancel()
        state.task = nil
        state.exportTask?.cancel()
        state.exportTask = nil
        if let speech = state.speech { playback.endSpeech(speech) }
        state.speech = nil
    }

    static func isReadingAloud(_ state: ReadAloudState) -> Bool { state.task != nil || state.exportTask != nil }
}

/// Read aloud speaks the displayed transcript of the selected record through
/// the shared playback, so speech and History playback are never audible
/// together and share Play/Pause, Stop and the recording lockout. Long
/// transcripts are spoken as consecutive segments within Deepgram's limit.
extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func voiceOutputSettings() -> DesktopVoiceOutputSettings { settings.voiceOutput ?? .init() }

    package func saveVoiceOutput(_ voiceOutput: DesktopVoiceOutputSettings) {
        let label = (try? DesktopSpeechVoice.resolved(
            modelID: voiceOutput.modelID, voiceID: voiceOutput.voiceID
        ))?.label
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
        saveVoiceOutput(changed)
    }

    @discardableResult
    package func saveVoiceSynthesisOptions(_ options: VoiceSynthesisOptions) -> Bool {
        var changed = voiceOutputSettings()
        changed.speed = options.speed
        changed.pitch = options.pitch
        changed.useSSML = options.useSSML
        return persistVoiceOutput(changed, message: "Voice synthesis controls saved.")
    }

    @discardableResult
    package func saveVoiceGenerationOptions(_ options: VoiceGenerationOptions) -> Bool {
        var changed = voiceOutputSettings()
        changed.autoPlay = options.autoPlay
        changed.saveToRecordings = options.saveToRecordings
        return persistVoiceOutput(changed, message: "Generated voice playback and save preferences saved.")
    }

    private func persistVoiceOutput(_ voiceOutput: DesktopVoiceOutputSettings, message: String) -> Bool {
        guard !closed else { return false }
        var changed = settings
        changed.voiceOutput = voiceOutput
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
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
        stopReadAloud()
        let ticket = playbackRequests.begin()
        let pronunciations: [PronunciationEntry]
        do {
            let vocabulary = try await vocabularyStore()
            pronunciations = await vocabulary.entries
        } catch {
            guard playbackRequests.isCurrent(ticket), !closed else { return }
            update("Pronunciation dictionary could not be loaded: \(error.localizedDescription)")
            return
        }
        guard playbackRequests.isCurrent(ticket), !closed, canUseHistory, selectedHistoryID == id,
              isVisible(id) else { return }
        let rendered = PronunciationRenderer().applyReplacements(to: text, entries: pronunciations)
        let segments = SpeechTextSegmenter.segments(rendered)
        guard !segments.isEmpty else { update("There is no transcript to read aloud."); return }
        startVoiceRead(text: text, owner: id, recordID: id)
    }

    package func readVoiceSource(_ snapshot: VoiceOutputSourceSnapshot) {
        if let id = snapshot.recordID { readAloud(id.uuidString, text: snapshot.text); return }
        guard !closed, canUseHistory else { return }
        startVoiceRead(text: snapshot.text, owner: UUID(), recordID: nil)
    }

    private func startVoiceRead(text: String, owner: UUID, recordID: UUID?) {
        let selection: DesktopSpeechSelection
        do { selection = try voiceOutputSettings().synthesisSelection() } catch {
            update(error.localizedDescription); return
        }
        let staging = directory.appendingPathComponent("VoiceOutput")
        let voiceOutput: Platform.VoiceOutput?
        if case .deepgram = selection.voice {
            guard let output = readAloudState.output({ try Platform.makeVoiceOutput(stagingDirectory: staging) }) else {
                update("Read aloud is unavailable: its private audio folder could not be prepared.")
                return
            }
            voiceOutput = output
        } else {
            voiceOutput = nil
        }
        let speech: Platform.Playback.Speech
        do {
            // Playback stops now, and the record's controls stay active until the speech ends.
            speech = try playback.beginSpeech(recordID: owner)
        } catch {
            update("Read aloud failed: \(error.localizedDescription)")
            return
        }
        let voice = selection.voice
        let ticket = playbackRequests.begin()
        readAloudState.speech = speech
        voiceOutputRecordID = recordID
        update("Reading aloud with \(voice.name)…")
        activeOperations += 1
        readAloudState.task = Task {
            defer { self.finishOperation() }
            var outcome: String?
            do {
                try await self.executeVoiceRead(
                    text: text, recordID: recordID, selection: selection, output: voiceOutput, speech: speech
                )
                outcome = "Finished reading aloud."
            } catch is CancellationError {
                outcome = "Reading aloud stopped."
            } catch DeepgramSpeechError.missingCredential {
                outcome = "Save a Deepgram API key (\(Platform.deepgramKeyHint)) to read aloud."
            } catch {
                outcome = "Read aloud failed: \(error.localizedDescription)"
            }
            self.finishReadAloud(ticket, status: outcome)
        }
    }

    private func executeVoiceRead(
        text: String, recordID: UUID?, selection: DesktopSpeechSelection,
        output: Platform.VoiceOutput?, speech: Platform.Playback.Speech
    ) async throws {
        let effects = effects
        let playback = playback
        if case .deepgram(let voice) = selection.voice, let output {
            for segment in SpeechTextSegmenter.segments(text) {
                try Task.checkCancellation()
                let request = try DeepgramSpeechRequest(text: segment, voice: voice, speed: selection.options.speed)
                _ = try await output.speak(request, credential: {
                    try effects.apiKey(name: selection.voice.apiKeyIdentifier)
                }, through: { file in
                    try await playback.playToCompletion(speech, path: file.path)
                })
            }
        } else {
            let source = try VoiceOutputSourceSnapshot(
                source: recordID == nil ? .typedText : .history, text: text, recordID: recordID
            )
            let wav = try await Platform.synthesizeVoiceOutput(source, selection: selection) {
                try effects.apiKey(name: selection.voice.apiKeyIdentifier)
            }
            try await DesktopVoicePlaybackFile.play(
                VoiceGeneratedAudio(validating: wav),
                directory: directory.appendingPathComponent("VoiceGeneratedPlayback"),
                prepare: { try Platform.preparePrivateDirectory($0) },
                through: { try await playback.playToCompletion(speech, path: $0.path) }
            )
        }
    }

    private func finishReadAloud(_ ticket: DesktopPlaybackRequests.Ticket, status: String?) {
        guard playbackRequests.isCurrent(ticket) else { return }
        // The finishing task is not cancelled; only its speech is ended.
        readAloudState.task = nil
        voiceOutputRecordID = nil
        Platform.stopReadAloud(&readAloudState, playback: playback)
        guard !closed, !busy, recording == nil, let status else { return }
        update(status)
    }
}
