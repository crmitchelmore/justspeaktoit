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
    static func voiceTextImported(_ result: Result<String, Error>, requestID: String) {
        let text: String
        let error: String
        switch result {
        case .success(let value): text = value; error = ""
        case .failure(let failure): text = ""; error = failure.localizedDescription
        }
        let status = requestID.withCString { token in
            text.withCString { value in
                error.withCString { jsti_window_set_voice_text_import(token, value, $0) }
            }
        }
        if status < 0 { LinuxHostPlatform.update("The text import result could not be shown.") }
    }

    static func voiceSources(context: UnsafeMutableRawPointer) {
        let strings = Strings()
        let sources = VoiceOutputSource.allCases.filter { $0 != .externalSelection }
        let names: [UnsafePointer<CChar>?] = sources.map { strings.add($0.displayName) }
        let result = withExtendedLifetime(strings) {
            names.withUnsafeBufferPointer {
                jsti_window_set_voice_sources($0.baseAddress, $0.count, linuxVoiceSourceEvent, context)
            }
        }
        if result != 0 { LinuxHostPlatform.update("The Voice Output sources could not be shown.") }
    }
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

// swiftlint:disable:next function_parameter_count
func linuxVoiceSourceEvent(
    _ action: Int32, _ source: Int32, _ text: UnsafePointer<CChar>?,
    _ record: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    if action == 112 { holder.submitHistoryPlayback(.stop); return }
    if action == 113 {
        holder.submitHistoryPlayback(.voiceImport(
            path: path.map(String.init(cString:)) ?? "", requestID: record.map(String.init(cString:)) ?? ""
        ))
        return
    }
    if action == 114 {
        holder.submitHistoryPlayback(.voiceImportCancel(requestID: record.map(String.init(cString:)) ?? ""))
        return
    }
    do {
        guard let source = VoiceOutputSource(rawValue: source) else {
            throw VoiceOutputSourceSnapshot.Failure.invalidText
        }
        let snapshot = try VoiceOutputSourceSnapshot(
            source: source, text: text.map(String.init(cString:)) ?? "",
            recordID: record.flatMap { UUID(uuidString: String(cString: $0)) }
        )
        if action == 110 { holder.submitHistoryPlayback(.voiceRead(snapshot)) }
        if action == 111 {
            holder.submitHistoryPlayback(.voiceExport(snapshot, path: path.map(String.init(cString:)) ?? ""))
        }
    } catch { LinuxHostPlatform.update(error.localizedDescription) }
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
