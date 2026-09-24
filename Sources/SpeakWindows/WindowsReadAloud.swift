import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform
import CWindowsSupport

/// The voice Read aloud uses, persisted as catalogue identifiers so a retired
/// or unknown voice resolves through the canonical catalogue's migrations.
struct WindowsVoiceOutputSettings: Codable, Equatable, Sendable {
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
        "\(voice.displayName) — \(voice.model.displayName)"
    }
}

extension WindowsNative {
    static func configureVoiceOutput(_ settings: WindowsVoiceOutputSettings, context: UnsafeMutableRawPointer) -> Bool {
        let voices = WindowsVoiceOutputSettings.voices
        guard let selected = voices.firstIndex(of: settings.voice) ?? voices.indices.first else { return false }
        let labels = voices.map(WindowsVoiceOutputSettings.label).map { Array($0.utf8CString) }
        let pointers = labels.map { chars -> UnsafeMutablePointer<CChar> in
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
            pointer.initialize(from: chars, count: chars.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let borrowed: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        return borrowed.withUnsafeBufferPointer {
            jsti_window_set_voice_output($0.baseAddress, $0.count, Int32(selected), voiceOutputEvent, context) == 0
        }
    }
}

/// Apply from the native Voice output dialog, on the UI thread.
func voiceOutputEvent(_ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let voices = WindowsVoiceOutputSettings.voices
    guard voices.indices.contains(Int(index)) else { return }
    let settings = WindowsVoiceOutputSettings(voice: voices[Int(index)])
    holder.enqueueSettings {
        await holder.controller.saveVoiceOutput(settings)
        let saved = await holder.controller.voiceOutputSettings()
        if !WindowsNative.configureVoiceOutput(saved, context: Unmanaged.passUnretained(holder).toOpaque()) {
            WindowsNative.update("The saved voice could not be shown. Reopen Voice and try again.")
        }
    }
}

/// The controller's Read aloud state. The engine and its private folder are
/// created on first use, never at launch. Which Read aloud may still report
/// is decided by the controller's shared `playbackRequests`.
struct WindowsReadAloudState {
    var task: Task<Void, Never>?
    /// Keeps the record's playback controls active, so Pause and Stop work
    /// while segments are synthesised and between them.
    var speech: WindowsAudioPlaybackController.Speech?
    private(set) var engine: WindowsVoiceOutput?

    mutating func output(directory: URL) -> WindowsVoiceOutput? {
        if engine == nil {
            engine = try? WindowsVoiceOutput(stagingDirectory: directory.appendingPathComponent("VoiceOutput"))
        }
        return engine
    }
}

/// Read aloud speaks the displayed transcript of the selected record through
/// the shared playback controller, so speech and History playback are never
/// audible together and share Play/Pause, Stop and the recording lockout.
/// Long transcripts are spoken as consecutive segments within Deepgram's limit.
extension WindowsAppController {
    func voiceOutputSettings() -> WindowsVoiceOutputSettings { settings.voiceOutput ?? .init() }

    func saveVoiceOutput(_ voiceOutput: WindowsVoiceOutputSettings) {
        guard !closed else { return }
        var changed = settings
        changed.voiceOutput = voiceOutput
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            guard !busy, recording == nil else { return }
            update("Read aloud voice saved: \(WindowsVoiceOutputSettings.label(voiceOutput.voice)).")
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
        let speech: WindowsAudioPlaybackController.Speech
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
                outcome = "Save a Deepgram API key (choose a Deepgram model, then Save key) to read aloud."
            } catch {
                outcome = "Read aloud failed: \(error.localizedDescription)"
            }
            self.finishReadAloud(ticket, status: outcome)
        }
    }

    private func finishReadAloud(_ ticket: DesktopPlaybackRequests.Ticket, status: String?) {
        guard playbackRequests.isCurrent(ticket) else { return }
        WindowsHostPlatform.stopReadAloud(&readAloudState, playback: playback)
        guard !closed, !busy, recording == nil, let status else { return }
        update(status)
    }
}
