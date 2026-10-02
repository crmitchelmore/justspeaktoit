import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// The Read aloud voice, persisted as catalogue identifiers like Windows'.
typealias LinuxVoiceOutputSettings = DesktopVoiceOutputSettings

/// Read aloud uses the controller implementation shared with Windows: the
/// displayed transcript is spoken with Deepgram, in segments, through the
/// History player. Synthesized audio is staged in the app's private data
/// folder (`VoiceOutput`, 0700) only while it plays.
extension LinuxHostPlatform: DesktopHostReadAloudPlatform {
    typealias ReadAloudState = DesktopHostReadAloudState<LinuxAudioPlayback.Speech, LinuxVoiceOutput>

    package static func makeVoiceOutput(stagingDirectory directory: URL) throws -> LinuxVoiceOutput {
        try LinuxVoiceOutput(stagingDirectory: directory)
    }

    package static let deepgramKeyHint =
        "choose a Deepgram model, then enter it as the API key for the selected provider"
}

// History playback and Read aloud share one player, so only one is ever
// audible and Play/Pause and Stop act on either.
extension LinuxAudioPlayback: DesktopHostPlayback, DesktopHostSpeechPlayback {}

extension LinuxVoiceOutput: DesktopHostVoiceOutput {}

extension LinuxWindow {
    /// Fills the voice picker from the canonical catalogue and selects the
    /// saved voice, or the catalogue default for a retired one.
    static func voiceOutput(_ settings: LinuxVoiceOutputSettings) {
        let voices = LinuxVoiceOutputSettings.voices
        let strings = Strings()
        let names: [UnsafePointer<CChar>?] = voices.map { strings.add(LinuxVoiceOutputSettings.label($0)) }
        let selected = voices.firstIndex(of: settings.voice) ?? 0
        let result = withExtendedLifetime(strings) {
            names.withUnsafeBufferPointer { jsti_window_set_voices($0.baseAddress, $0.count, Int32(selected)) }
        }
        if result != 0 { LinuxHostPlatform.update("The Read aloud voices could not be shown.") }
    }
}

/// Read aloud and voice picker events. Returns false for others.
func linuxReadAloudEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    switch event {
    case Int(JSTI_EVENT_READ_ALOUD): holder.readAloud(value)
    case Int(JSTI_EVENT_VOICE_OUTPUT): holder.selectVoice(slot)
    default: return false
    }
    return true
}

extension LinuxEventContext {
    /// Like Export, Read aloud captures the displayed text on the GTK thread
    /// at the click, paired with the record ID its event carries, and joins
    /// the History order after the selection before it.
    func readAloud(_ identifier: String) {
        do {
            submitHistoryPlayback(.readAloud(identifier, text: try LinuxWindow.displayedTranscript()))
        } catch { LinuxHostPlatform.update(error.localizedDescription) }
    }

    /// Saves the chosen voice in settings order, then shows what was saved.
    func selectVoice(_ index: Int) {
        let voices = LinuxVoiceOutputSettings.voices
        guard voices.indices.contains(index) else { return }
        let settings = LinuxVoiceOutputSettings(voice: voices[index])
        let controller = controller
        enqueueSettings {
            await controller.saveVoiceOutput(settings)
            LinuxWindow.voiceOutput(await controller.voiceOutputSettings())
        }
    }
}
