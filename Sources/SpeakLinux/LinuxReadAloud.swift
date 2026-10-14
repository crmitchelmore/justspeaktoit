import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// The Read aloud voice, persisted as catalogue identifiers like Windows'.
typealias LinuxVoiceOutputSettings = DesktopVoiceOutputSettings

/// Read aloud uses the controller implementation shared with Windows: the
/// immutable snapshot is spoken with the selected executable provider through
/// the History player. Synthesized audio remains in private staging only while
/// it plays; shared route capabilities govern the stored synthesis controls.
extension LinuxHostPlatform: DesktopHostReadAloudPlatform {
    typealias ReadAloudState = DesktopHostReadAloudState<LinuxAudioPlayback.Speech, LinuxVoiceOutput>

    package static func makeVoiceOutput(stagingDirectory directory: URL) throws -> LinuxVoiceOutput {
        try LinuxVoiceOutput(stagingDirectory: directory)
    }

    package static let deepgramKeyHint =
        "choose a Deepgram model, then enter it as the API key for the selected provider"
}

extension LinuxHostPlatform {
    package static func voiceDiscovery(_ shown: DesktopVoiceDiscoveryPresentation) {
        let labels = shown.voices.map {
            $0.label + (DesktopSpeechVoice.voices.contains($0) ? " (documented preset)" : " (account listing)")
        }.joined(separator: "\n")
        let ids = shown.voices.map(\.id).joined(separator: "\n")
        let result = shown.requestID.withCString { token in
            labels.withCString { names in
                ids.withCString { identifiers in
                    shown.message.withCString {
                        jsti_window_set_voice_account_inventory(
                            token, names, identifiers, Int32(shown.selected), $0, shown.loading ? 1 : 0)
                    }
                }
            }
        }
        if result != 0 { update("The account voice listing could not be shown.") }
        LinuxWindow.voiceOutput(shown.settings, inventory: shown.inventory)
    }
    package static func voiceUsage(_ presentation: DesktopVoiceUsagePresentation) {
        let result = presentation.requestID.withCString { token in
            presentation.text.withCString {
                jsti_window_set_voice_usage(token, $0, presentation.trackingEnabled ? 1 : 0)
            }
        }
        if result < 0 { update("The Voice usage report could not be shown.") }
    }

    package static func voiceTextImportCancelled(_ requestID: String) {
        let result = requestID.withCString { token in
            "".withCString { empty in
                "Text import stopped.".withCString { jsti_window_set_voice_text_import(token, empty, $0) }
            }
        }
        if result < 0 { update("The stopped text import could not be shown.") }
    }

    package static func voiceGenerated(_ presentation: DesktopVoiceResultPresentation) {
        let result = presentation.resultID.withCString { identifier in
            presentation.message.withCString {
                jsti_window_set_voice_generated_result(identifier, presentation.working ? 1 : 0, $0)
            }
        }
        if result < 0 { update("The generated voice result could not be shown.") }
    }
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
        if jsti_window_set_voice_credential_handler(linuxVoiceCredentialEvent, context) != 0 {
            LinuxHostPlatform.update("The Voice provider key entry could not be configured.")
        }
    }
    /// Fills the voice picker from the canonical catalogue and selects the
    /// saved voice, or the catalogue default for a retired one.
    static func voiceOutput(_ settings: LinuxVoiceOutputSettings, inventory: XAIAccountVoiceInventory? = nil) {
        let presentation = settings.pickerPresentation(inventory: inventory)
        let strings = Strings()
        let names: [UnsafePointer<CChar>?] = presentation.labels.map { strings.add($0) }
        let selected = presentation.selected
        let result = withExtendedLifetime(strings) {
            names.withUnsafeBufferPointer { jsti_window_set_voices($0.baseAddress, $0.count, Int32(selected)) }
        }

        if result != 0 { LinuxHostPlatform.update("The Read aloud voices could not be shown.") }
        if jsti_window_set_voice_generation_options(settings.generationOptions.nativeFlags) != 0 {
            LinuxHostPlatform.update("The generated voice preferences could not be shown.")
        }
        voiceControls(settings, inventory: inventory)
    }

    static func voiceControls(_ settings: LinuxVoiceOutputSettings, inventory: XAIAccountVoiceInventory? = nil) {
        let shown = settings.controlsPresentation(inventory: inventory)
        let result = shown.label.withCString {
            jsti_window_set_voice_synthesis_options_with_limits(
                shown.speed, shown.pitch, shown.ssml, shown.capabilities, $0,
                shown.minimumSpeed, shown.maximumSpeed)
        }
        if result != 0 { LinuxHostPlatform.update("The saved Voice synthesis controls could not be shown.") }
    }
}

// swiftlint:disable:next function_parameter_count
func linuxVoiceSourceEvent(
    _ action: Int32, _ source: Int32, _ text: UnsafePointer<CChar>?,
    _ record: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    do {
        let message = try DesktopVoiceSourceMessage(
            action: action, source: source, text: text.map(String.init(cString:)) ?? "",
            record: record.map(String.init(cString:)) ?? "", path: path.map(String.init(cString:)) ?? ""
        )
        switch message {
        case .discoveryOpen, .discoveryOpenModern, .discoveryRefresh,
             .discoveryClose, .discoveryChoose, .discoveryProvider:
            holder.enqueueSettings { await holder.controller.handleVoiceDiscovery(message) }
        case .event(let event): holder.submitHistoryPlayback(event)
        case .preferences(let options):
            holder.enqueueSettings {
                await holder.controller.saveVoiceGenerationOptions(options)
                let saved = await holder.controller.voiceOutputSettings()
                if jsti_window_set_voice_generation_options(saved.generationOptions.nativeFlags) != 0 {
                    LinuxHostPlatform.update("The saved Voice Output preferences could not be shown.")
                }
            }
        case .usageReport(let text, let requestID):
            holder.enqueueSettings { await holder.controller.showVoiceUsage(text: text, requestID: requestID) }
        case .usageTracking(let enabled, let requestID):
            holder.enqueueSettings { await holder.controller.saveVoiceUsageTracking(enabled, requestID: requestID) }
        case .synthesisPreferences(let options, let requestID):
            holder.enqueueSettings {
                let saved = await holder.controller.saveVoiceSynthesisOptions(options)
                LinuxWindow.voiceControls(await holder.controller.voiceOutputSettings(),
                    inventory: await holder.controller.currentVoiceInventory())
                if requestID.withCString({ jsti_window_finish_voice_synthesis_options($0, saved ? 1 : 0) }) != 0 {
                    LinuxHostPlatform.update("The Voice controls save result could not be shown.")
                }
            }
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
        let voices = DesktopSpeechVoice.voices
        guard voices.indices.contains(index) else { return }
        let controller = controller
        enqueueSettings {
            await controller.selectVoiceOutput(voices[index])
            LinuxWindow.voiceOutput(await controller.voiceOutputSettings())
        }
    }
}
