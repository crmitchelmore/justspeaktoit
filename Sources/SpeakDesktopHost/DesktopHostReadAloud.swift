import Foundation
import SpeakCore
import SpeakDesktop

/// The voice Read aloud uses, persisted as catalogue identifiers so a retired
/// or unknown voice resolves through the canonical catalogue's migrations.
package struct DesktopVoiceOutputSettings: Codable, Equatable, Sendable {
    package var modelID: String?
    package var voiceID: String?

    package var voice: DeepgramSpeechCatalog.Voice {
        DeepgramSpeechCatalog.resolvedSelection(modelID: modelID, voiceID: voiceID).voice
    }

    package init(modelID: String? = nil, voiceID: String? = nil) {
        self.modelID = modelID
        self.voiceID = voiceID
    }

    package init(voice: DeepgramSpeechCatalog.Voice) {
        self.init(modelID: voice.model.id, voiceID: voice.id)
    }

    /// Picker order: the canonical catalogue, never a host-owned copy.
    package static var voices: [DeepgramSpeechCatalog.Voice] { DeepgramSpeechCatalog.voices }
    package static func label(_ voice: DeepgramSpeechCatalog.Voice) -> String {
        "\(voice.displayName) — \(voice.model.displayName)"
    }
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
    /// Where this window saves the Deepgram key, e.g. "choose a Deepgram
    /// model, then Save key", for the missing-key status line.
    static var deepgramKeyHint: String { get }
}

package extension DesktopHostReadAloudPlatform {
    static func makeReadAloudState() -> ReadAloudState { ReadAloudState() }

    /// Cancels the segment being synthesized, so no later one is admitted, and
    /// returns the record's controls to idle once nothing more will be spoken.
    static func stopReadAloud(_ state: inout ReadAloudState, playback: Playback) {
        state.task?.cancel()
        state.task = nil
        if let speech = state.speech { playback.endSpeech(speech) }
        state.speech = nil
    }

    static func isReadingAloud(_ state: ReadAloudState) -> Bool { state.task != nil }
}

/// Read aloud speaks the displayed transcript of the selected record through
/// the shared playback, so speech and History playback are never audible
/// together and share Play/Pause, Stop and the recording lockout. Long
/// transcripts are spoken as consecutive segments within Deepgram's limit.
extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func voiceOutputSettings() -> DesktopVoiceOutputSettings { settings.voiceOutput ?? .init() }

    package func saveVoiceOutput(_ voiceOutput: DesktopVoiceOutputSettings) {
        guard !closed else { return }
        var changed = settings
        changed.voiceOutput = voiceOutput
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            guard !busy, recording == nil else { return }
            update("Read aloud voice saved: \(DesktopVoiceOutputSettings.label(voiceOutput.voice)).")
        } catch { update("Could not save the voice: \(error.localizedDescription)") }
    }

    /// `text` is the transcript displayed for `identifier` when Read aloud was clicked.
    package func readAloud(_ identifier: String, text: String) {
        guard !closed, canUseHistory, let id = UUID(uuidString: identifier), history[id] != nil,
              selectedHistoryID == id, isVisible(id) else { return }
        let segments = SpeechTextSegmenter.segments(text)
        guard !segments.isEmpty else { update("There is no transcript to read aloud."); return }
        let staging = directory.appendingPathComponent("VoiceOutput")
        guard let voiceOutput = readAloudState.output({ try Platform.makeVoiceOutput(stagingDirectory: staging) })
        else {
            update("Read aloud is unavailable: its private audio folder could not be prepared.")
            return
        }
        stopReadAloud()
        let speech: Platform.Playback.Speech
        do {
            // Playback stops now, and the record's controls stay active until the speech ends.
            speech = try playback.beginSpeech(recordID: id)
        } catch {
            update("Read aloud failed: \(error.localizedDescription)")
            return
        }
        let voice = voiceOutputSettings().voice
        let effects = effects
        let playback = playback
        let ticket = playbackRequests.begin()
        readAloudState.speech = speech
        update("Reading aloud with \(voice.name)…")
        readAloudState.task = Task {
            var outcome: String?
            do {
                for segment in segments {
                    try Task.checkCancellation()
                    let request = try DeepgramSpeechRequest(text: segment, voice: voice)
                    _ = try await voiceOutput.speak(request, credential: {
                        try effects.apiKey(name: VoiceOutputProvider.deepgram.apiKeyIdentifier)
                    }, through: { file in
                        try await playback.playToCompletion(speech, path: file.path)
                    })
                }
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

    private func finishReadAloud(_ ticket: DesktopPlaybackRequests.Ticket, status: String?) {
        guard playbackRequests.isCurrent(ticket) else { return }
        // The finishing task is not cancelled; only its speech is ended.
        readAloudState.task = nil
        Platform.stopReadAloud(&readAloudState, playback: playback)
        guard !closed, !busy, recording == nil, let status else { return }
        update(status)
    }
}
