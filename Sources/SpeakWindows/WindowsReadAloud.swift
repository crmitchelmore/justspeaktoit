import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
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
            jsti_window_set_voice_generation_options(settings.generationOptions.nativeFlags) == 0 &&
            configureVoiceLanguageTitle(settings, accountInventory: accountInventory) &&
            configureVoiceControls(settings, accountInventory: accountInventory)
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
        let strings = ConfigurationStrings()
        let examples = VoiceSynthesisMarkup.examples.map {
            JSTIVoiceMarkupExample(text: strings.add($0.text), description: strings.add($0.description))
        }
        let helper = withExtendedLifetime(strings) {
            examples.withUnsafeBufferPointer {
                jsti_window_set_voice_markup_helper(
                    shown.markupHelperEnabled ? 1 : 0, $0.baseAddress, $0.count
                ) { input, output, capacity, utf16, scalars in
                    VoiceSynthesisMarkup.writeWrappedText(input, output: output, capacity: capacity,
                        leadingUTF16: utf16, leadingScalars: scalars)
                }
            }
        }
        return configured && helper == 0
    }

    static func voiceDiscovery(_ shown: DesktopVoiceDiscoveryPresentation) {
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
        guard let context = voiceContext.get(), result == 0,
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
        if status < 0 { WindowsNative.update("The text import result could not be shown.") }
    }

}

extension WindowsHostPlatform {
    package static func voiceDiscovery(_ presentation: DesktopVoiceDiscoveryPresentation) {
        WindowsNative.voiceDiscovery(presentation)
    }
    package static func voiceUsage(_ presentation: DesktopVoiceUsagePresentation) {
        let result = presentation.requestID.withCString { token in
            presentation.text.withCString {
                jsti_window_set_voice_usage(token, $0, presentation.trackingEnabled ? 1 : 0)
            }
        }
        if result < 0 { WindowsNative.update("The Voice usage report could not be shown.") }
    }

    package static func voiceTextImportCancelled(_ requestID: String) {
        let result = requestID.withCString { token in
            "".withCString { empty in
                "Text import stopped.".withCString { jsti_window_set_voice_text_import(token, empty, $0) }
            }
        }
        if result < 0 { WindowsNative.update("The stopped text import could not be shown.") }
    }

    package static func voiceGenerated(_ presentation: DesktopVoiceResultPresentation) {
        let result = presentation.resultID.withCString { identifier in
            presentation.message.withCString {
                jsti_window_set_voice_generated_result(identifier, presentation.working ? 1 : 0, $0)
            }
        }
        if result < 0 { WindowsNative.update("The generated voice result could not be shown.") }
    }
}

// swiftlint:disable:next function_parameter_count
func windowsVoiceSourceEvent(
    _ action: Int32, _ source: Int32, _ text: UnsafePointer<CChar>?,
    _ record: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
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
                    WindowsNative.update("The saved Voice Output preferences could not be shown.")
                }
            }
        case .usageReport(let text, let requestID):
            holder.enqueueSettings { await holder.controller.showVoiceUsage(text: text, requestID: requestID) }
        case .usageTracking(let enabled, let requestID):
            holder.enqueueSettings { await holder.controller.saveVoiceUsageTracking(enabled, requestID: requestID) }
        case .synthesisPreferences(let options, let requestID):
            saveWindowsVoiceControls(options, requestID: requestID, holder: holder)
        }
    } catch { WindowsNative.update(error.localizedDescription) }
}

private func saveWindowsVoiceControls(
    _ options: VoiceSynthesisOptions, requestID: String, holder: WindowsEventContext
) {
    holder.enqueueSettings {
        let saved = await holder.controller.saveVoiceSynthesisOptions(options)
        if !WindowsNative.configureVoiceControls(await holder.controller.voiceOutputSettings(),
            accountInventory: await holder.controller.selectedVoiceAccountInventory) {
            WindowsNative.update("The saved Voice synthesis controls could not be shown.")
        }
        if requestID.withCString({ jsti_window_finish_voice_synthesis_options($0, saved ? 1 : 0) }) != 0 {
            WindowsNative.update("The Voice controls save result could not be shown.")
        }
    }
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
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    holder.enqueueSettings {
        await holder.controller.handleVoicePicker(voiceID: voiceID, action: action)
        if !WindowsNative.configureVoiceOutput(await holder.controller.voiceOutputSettings(),
            context: Unmanaged.passUnretained(holder).toOpaque(),
            accountInventory: await holder.controller.selectedVoiceAccountInventory) {
            WindowsNative.update("The saved favorite voices could not be shown. Reopen Voice and try again.")
        }
    }
}

/// Apply from the native Voice output dialog, on the UI thread.
func voiceOutputEvent(_ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let voices = DesktopSpeechVoice.voices
    guard voices.indices.contains(Int(index)) else { return }
    holder.enqueueSettings {
        await holder.controller.selectVoiceOutput(voices[Int(index)])
        let saved = await holder.controller.voiceOutputSettings()
        if !WindowsNative.configureVoiceOutput(saved, context: Unmanaged.passUnretained(holder).toOpaque()) {
            WindowsNative.update("The saved voice could not be shown. Reopen Voice and try again.")
        }
    }
}
