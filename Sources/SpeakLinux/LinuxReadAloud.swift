import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings
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
    package static func showVoiceAudioFormats(_ settings: DesktopVoiceOutputSettings, status: String) {
        LinuxWindow.voiceAudioFormats(settings, status: status)
    }

    package static func showVoiceControls(
        _ settings: DesktopVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) {
        LinuxWindow.voiceControls(settings, accountInventory: accountInventory)
    }

    package static func voiceDiscovery(_ shown: DesktopVoiceDiscoveryPresentation) {
        if !showVoiceAccountInventory(shown) { update("The account voice listing could not be shown.") }
        LinuxWindow.voiceOutput(shown.settings,
            accountInventory: shown.accountInventory ?? shown.inventory.map(VoiceAccountInventory.xai))
    }
}

// History playback and Read aloud share one player, so only one is ever
// audible and Play/Pause and Stop act on either.
extension LinuxAudioPlayback: DesktopHostPlayback, DesktopHostSpeechPlayback {}

extension LinuxVoiceOutput: DesktopHostVoiceOutput {}

extension LinuxWindow {
    static func voiceSources(context: UnsafeMutableRawPointer) {
        let strings = DesktopNativeStrings()
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
        voiceOutput(settings, accountInventory: inventory.map(VoiceAccountInventory.xai))
    }

    static func voiceOutput(_ settings: LinuxVoiceOutputSettings, accountInventory: VoiceAccountInventory?) {
        let presentation = settings.favoritePicker(accountInventory: accountInventory)
        let strings = DesktopNativeStrings()
        let names: [UnsafePointer<CChar>?] = presentation.labels.map { strings.add($0) }
        let identifiers: [UnsafePointer<CChar>?] = presentation.identifiers.map { strings.add($0) }
        let selected = presentation.selected
        let result = withExtendedLifetime(strings) {
            names.withUnsafeBufferPointer { names in
                identifiers.withUnsafeBufferPointer { identifiers in
                    presentation.favoriteRanks.withUnsafeBufferPointer {
                        jsti_window_set_voice_picker(names.baseAddress, identifiers.baseAddress, $0.baseAddress,
                            names.count, Int32(selected), linuxVoicePickerEvent, nil)
                    }
                }
            }
        }

        if result != 0 { LinuxHostPlatform.update("The Read aloud voices could not be shown.") }
        voiceAudioFormats(settings)
        if jsti_window_set_voice_generation_options(settings.generationOptions.nativeFlags) != 0 {
            LinuxHostPlatform.update("The generated voice preferences could not be shown.")
        }
        voiceLanguageTitle(settings, accountInventory: accountInventory)
        voiceControls(settings, accountInventory: accountInventory)
    }

    static func voiceAudioFormats(_ settings: LinuxVoiceOutputSettings, status: String = "") {
        let rows = VoiceAudioFormat.allCases.map { $0.rawValue + "\t" + $0.displayName }.joined(separator: "\n")
        let result = rows.withCString { rows in
            (settings.format ?? VoiceAudioFormat.desktopLegacyDefault.rawValue).withCString { selected in
                status.withCString { jsti_window_set_voice_audio_formats(rows, selected, $0) }
            }
        }
        if result != 0 { LinuxHostPlatform.update("The saved Voice file format could not be shown.") }
    }

    static func voiceControls(_ settings: LinuxVoiceOutputSettings, inventory: XAIAccountVoiceInventory? = nil) {
        voiceControls(settings, accountInventory: inventory.map(VoiceAccountInventory.xai))
    }

    static func voiceControls(_ settings: LinuxVoiceOutputSettings, accountInventory: VoiceAccountInventory?) {
        let shown = settings.controlsPresentation(accountInventory: accountInventory)
        let result = shown.label.withCString { label in
            shown.guidance.withCString {
                jsti_window_set_voice_synthesis_options_with_details(
                    shown.speed, shown.pitch, shown.ssml, shown.capabilities, label,
                    shown.minimumSpeed, shown.maximumSpeed, $0)
            }
        }
        if result != 0 { LinuxHostPlatform.update("The saved Voice synthesis controls could not be shown.") }
        if !DesktopNativeBindings.voiceMarkupHelper(enabled: shown.markupHelperEnabled) {
            LinuxHostPlatform.update("The Voice SSML helper could not be configured.")
        }
    }
}

func linuxVoicePickerEvent(_ action: Int32, _ identifier: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    // The window forwards its existing UI callback context, not a new native holder.
    guard let identifier, let context else { return }
    let voiceID = String(cString: identifier)
    guard let holder = NativeCallbackContext<LinuxEventContext>.resolve(context) else { return }
    holder.enqueueSettings {
        await holder.controller.handleVoicePicker(voiceID: voiceID, action: action)
        LinuxWindow.voiceOutput(await holder.controller.voiceOutputSettings(),
            accountInventory: await holder.controller.selectedVoiceAccountInventory)
    }
}

// The native callback's parameter list is fixed by the C ABI.
// swiftlint:disable:next function_parameter_count
func linuxVoiceSourceEvent(
    _ action: Int32, _ source: Int32, _ text: UnsafePointer<CChar>?,
    _ record: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    LinuxEventContext.voiceSourceEvent(
        action: action, source: source, strings: [text, record, path], context: context
    )
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
    func speakSelectedText(lifetime: DesktopShortcutListenerLifetime? = nil) {
        guard let target = LinuxSelectedTextTarget.captureAdmitted() else {
            LinuxHostPlatform.update(LinuxSelectedTextTarget.availability)
            return
        }
        let deliver = {
            self.enqueueSettings {
                await self.controller.readVoiceSource(.externalSelection) { try await target.selectedText() }
            }
        }
        if let lifetime { lifetime.admitCallback(deliver) } else { deliver() }
    }

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
