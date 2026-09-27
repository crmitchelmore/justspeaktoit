import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// The voice Read aloud uses, persisted as catalogue identifiers (the same
/// keys as Windows) so a retired or unknown voice resolves through the
/// canonical Deepgram catalogue's migrations.
struct LinuxVoiceOutputSettings: Codable, Equatable, Sendable {
    var modelID: String?
    var voiceID: String?

    var voice: DeepgramSpeechCatalog.Voice {
        DeepgramSpeechCatalog.resolvedSelection(modelID: modelID, voiceID: voiceID).voice
    }

    init(modelID: String? = nil, voiceID: String? = nil) {
        self.modelID = modelID
        self.voiceID = voiceID
    }

    init(voice: DeepgramSpeechCatalog.Voice) {
        self.init(modelID: voice.model.id, voiceID: voice.id)
    }

    static var voices: [DeepgramSpeechCatalog.Voice] { DeepgramSpeechCatalog.voices }

    static func label(_ voice: DeepgramSpeechCatalog.Voice) -> String {
        "\(voice.displayName) \u{2014} \(voice.model.displayName)"
    }
}

/// The controller's Read aloud state. The engine and its private folder are
/// created on first use, never at launch. Which Read aloud may still report is
/// decided by the controller's shared `playbackRequests`.
struct LinuxReadAloudState {
    var task: Task<Void, Never>?
    private(set) var engine: LinuxVoiceOutput?

    mutating func output(directory: URL) -> LinuxVoiceOutput? {
        if engine == nil {
            engine = try? LinuxVoiceOutput(stagingDirectory: directory.appendingPathComponent("VoiceOutput"))
        }
        return engine
    }

    mutating func stop() {
        task?.cancel()
        task = nil
    }
}

/// Read aloud speaks the displayed transcript of the selected record through
/// the app's single player, so speech and History playback are never audible
/// together and share Pause, Stop and the recording lockout. Long transcripts
/// are spoken as consecutive segments within Deepgram's limit.
extension LinuxAppController {
    func voiceOutputSettings() -> LinuxVoiceOutputSettings { settings.voiceOutput ?? .init() }

    func saveVoiceOutput(_ voiceOutput: LinuxVoiceOutputSettings) {
        guard !closed else { return }
        var changed = settings
        changed.voiceOutput = voiceOutput
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            guard !busy, recording == nil else { return }
            update("Read aloud voice saved: \(LinuxVoiceOutputSettings.label(voiceOutput.voice)).")
        } catch { update("Could not save the voice: \(error.localizedDescription)") }
    }

    /// `text` is the transcript displayed for `identifier` when Read aloud was clicked.
    func readAloud(_ identifier: String, text: String) {
        guard !closed, canUseHistory, let id = UUID(uuidString: identifier), history[id] != nil,
              selectedHistoryID == id, isVisible(id) else { return }
        let segments = SpeechTextSegmenter.segments(text)
        guard !segments.isEmpty else { update("There is no transcript to read aloud."); return }
        guard let voiceOutput = readAloudState.output(directory: directory) else {
            update("Read aloud is unavailable: its private audio folder could not be prepared.")
            return
        }
        stopReadAloud()
        playback.stop(announcing: false)
        let voice = voiceOutputSettings().voice
        let effects = effects
        let playback = playback
        let ticket = playbackRequests.begin()
        update("Reading aloud with \(voice.name)\u{2026}")
        readAloudState.task = Task {
            var outcome: String?
            do {
                for segment in segments {
                    try Task.checkCancellation()
                    let request = try DeepgramSpeechRequest(text: segment, voice: voice)
                    _ = try await voiceOutput.speak(request, credential: {
                        try effects.apiKey(name: VoiceOutputProvider.deepgram.apiKeyIdentifier)
                    }, through: { file in
                        try await playback.playToCompletion(recordID: id, path: file.path)
                    })
                }
                outcome = "Finished reading aloud."
            } catch is CancellationError {
                outcome = "Reading aloud stopped."
            } catch DeepgramSpeechError.missingCredential {
                outcome = "Save a Deepgram API key (choose a Deepgram model, then save its key) to read aloud."
            } catch {
                outcome = "Read aloud failed: \(error.localizedDescription)"
            }
            self.finishReadAloud(ticket, status: outcome)
        }
    }

    private func finishReadAloud(_ ticket: DesktopPlaybackRequests.Ticket, status: String?) {
        guard playbackRequests.isCurrent(ticket) else { return }
        readAloudState.task = nil
        guard !closed, !busy, recording == nil, let status else { return }
        update(status)
    }
}
