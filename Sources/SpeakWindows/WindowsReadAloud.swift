import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopNativeBindings
import SpeakWindowsPlatform
import CWindowsSupport

/// The Read aloud voice and the controller's Read aloud (segments, status and
/// the ticketed finish) are shared with Linux in `SpeakDesktopHost`.
typealias WindowsVoiceOutputSettings = DesktopVoiceOutputSettings

extension WindowsNative {
    private static let voiceContext = WindowsVoiceContext()
    static func configureVoiceOutput(_ settings: WindowsVoiceOutputSettings, context: UnsafeMutableRawPointer) -> Bool {
        configureVoiceOutput(settings, context: context, inventory: nil)
    }

    static func configureVoiceOutput(
        _ settings: WindowsVoiceOutputSettings, context: UnsafeMutableRawPointer, inventory: XAIAccountVoiceInventory?
    ) -> Bool {
        configureVoiceOutput(settings, context: context,
            accountInventory: inventory.map(VoiceAccountInventory.xai))
    }

    static func configureVoiceOutput(
        _ settings: WindowsVoiceOutputSettings, context: UnsafeMutableRawPointer,
        accountInventory: VoiceAccountInventory?
    ) -> Bool {
        voiceContext.set(context)
        let presentation = settings.favoritePicker(accountInventory: accountInventory)
        let selected = presentation.selected
        let labels = (presentation.labels + presentation.identifiers).map { Array($0.utf8CString) }
        let pointers = labels.map { chars -> UnsafeMutablePointer<CChar> in
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
            pointer.initialize(from: chars, count: chars.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let borrowed: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        let configured = borrowed.withUnsafeBufferPointer { names in
            presentation.favoriteRanks.withUnsafeBufferPointer { ranks in
                jsti_window_set_voice_picker(
                    names.baseAddress, names.baseAddress?.advanced(by: presentation.labels.count),
                    ranks.baseAddress, presentation.labels.count, Int32(selected),
                    windowsVoicePickerEvent, context) == 0
            }
        }
        return configured && configureVoiceSources(context: context) &&
            configureVoiceAudioFormats(settings) &&
            jsti_window_set_voice_generation_options(settings.generationOptions.nativeFlags) == 0 &&
            configureVoiceLanguageTitle(settings, accountInventory: accountInventory) &&
            configureVoiceControls(settings, accountInventory: accountInventory)
    }

    static func configureVoiceAudioFormats(_ settings: WindowsVoiceOutputSettings, status: String = "") -> Bool {
        let rows = VoiceAudioFormat.allCases.map { $0.rawValue + "\t" + $0.displayName }.joined(separator: "\n")
        return rows.withCString { rows in
            (settings.format ?? VoiceAudioFormat.desktopLegacyDefault.rawValue).withCString { selected in
                status.withCString { jsti_window_set_voice_audio_formats(rows, selected, $0) == 0 }
            }
        }
    }

    static func configureVoiceControls(
        _ settings: WindowsVoiceOutputSettings, inventory: XAIAccountVoiceInventory? = nil
    ) -> Bool {
        configureVoiceControls(settings, accountInventory: inventory.map(VoiceAccountInventory.xai))
    }

    static func configureVoiceControls(
        _ settings: WindowsVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) -> Bool {
        let shown = settings.controlsPresentation(accountInventory: accountInventory)
        let configured = shown.label.withCString { label in
            shown.guidance.withCString {
                jsti_window_set_voice_synthesis_options_with_details(
                    shown.speed, shown.pitch, shown.ssml, shown.capabilities, label,
                    shown.minimumSpeed, shown.maximumSpeed, $0) == 0
            }
        }
        let helper = DesktopNativeBindings.voiceMarkupHelper(enabled: shown.markupHelperEnabled)
        return configured && helper
    }

    static func voiceDiscovery(_ shown: DesktopVoiceDiscoveryPresentation) {
        guard let context = voiceContext.get(), WindowsHostPlatform.showVoiceAccountInventory(shown),
              configureVoiceOutput(shown.settings, context: context,
                  accountInventory: shown.accountInventory ?? shown.inventory.map(VoiceAccountInventory.xai)) else {
            update("The account voice listing or saved voice could not be shown."); return
        }
    }

    static func configureVoiceSources(context: UnsafeMutableRawPointer) -> Bool {
        let sources = VoiceOutputSource.allCases.filter { $0 != .externalSelection }
        let names = sources.map { Array($0.displayName.utf8CString) }
        let pointers = names.map { chars -> UnsafeMutablePointer<CChar> in
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
            pointer.initialize(from: chars, count: chars.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let borrowed: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        return borrowed.withUnsafeBufferPointer {
            jsti_window_set_voice_sources($0.baseAddress, $0.count, windowsVoiceSourceEvent, context) == 0 &&
                jsti_window_set_voice_credential_handler(windowsVoiceCredentialEvent, context) == 0
        }
    }
}

extension WindowsHostPlatform {
    package static func voiceDiscovery(_ presentation: DesktopVoiceDiscoveryPresentation) {
        WindowsNative.voiceDiscovery(presentation)
    }

    package static func showVoiceAudioFormats(_ settings: DesktopVoiceOutputSettings, status: String) {
        if !WindowsNative.configureVoiceAudioFormats(settings, status: status) {
            update("The saved Voice file format could not be shown.")
        }
    }

    package static func showVoiceControls(
        _ settings: DesktopVoiceOutputSettings, accountInventory: VoiceAccountInventory?
    ) {
        if !WindowsNative.configureVoiceControls(settings, accountInventory: accountInventory) {
            update("The saved Voice synthesis controls could not be shown.")
        }
    }
}

// The native callback's parameter list is fixed by the C ABI.
// swiftlint:disable:next function_parameter_count
func windowsVoiceSourceEvent(
    _ action: Int32, _ source: Int32, _ text: UnsafePointer<CChar>?,
    _ record: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    WindowsEventContext.voiceSourceEvent(
        action: action, source: source, strings: [text, record, path], context: context
    )
}

private final class WindowsVoiceContext: @unchecked Sendable {
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?
    func set(_ value: UnsafeMutableRawPointer) { lock.withLock { context = value } }
    func get() -> UnsafeMutableRawPointer? { lock.withLock { context } }
}

func windowsVoicePickerEvent(
    _ action: Int32, _ identifier: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let identifier, let context else { return }
    let voiceID = String(cString: identifier)
    guard let holder = NativeCallbackContext<WindowsEventContext>.resolve(context) else { return }
    holder.enqueueSettings {
        await holder.controller.handleVoicePicker(voiceID: voiceID, action: action)
        if !WindowsNative.configureVoiceOutput(await holder.controller.voiceOutputSettings(),
            context: holder.callbackContext,
            accountInventory: await holder.controller.selectedVoiceAccountInventory) {
            WindowsNative.update("The saved favorite voices could not be shown. Reopen Voice and try again.")
        }
    }
}

/// Apply from the native Voice output dialog, on the UI thread.
func voiceOutputEvent(_ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let holder = NativeCallbackContext<WindowsEventContext>.resolve(context) else { return }
    let voices = DesktopSpeechVoice.voices
    guard voices.indices.contains(Int(index)) else { return }
    holder.enqueueSettings {
        await holder.controller.selectVoiceOutput(voices[Int(index)])
        let saved = await holder.controller.voiceOutputSettings()
        if !WindowsNative.configureVoiceOutput(saved, context: holder.callbackContext) {
            WindowsNative.update("The saved voice could not be shown. Reopen Voice and try again.")
        }
    }
}
