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
        let configured = borrowed.withUnsafeBufferPointer {
            jsti_window_set_voice_output($0.baseAddress, $0.count, Int32(selected), voiceOutputEvent, context) == 0
        }
        return configured && configureVoiceSources(context: context) &&
            jsti_window_set_voice_generation_options(settings.generationOptions.nativeFlags) == 0
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
            jsti_window_set_voice_sources($0.baseAddress, $0.count, windowsVoiceSourceEvent, context) == 0
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
        case .event(let event): holder.submitHistoryPlayback(event)
        case .preferences(let options):
            holder.enqueueSettings {
                await holder.controller.saveVoiceGenerationOptions(options)
                let saved = await holder.controller.voiceOutputSettings()
                if jsti_window_set_voice_generation_options(saved.generationOptions.nativeFlags) != 0 {
                    WindowsNative.update("The saved Voice Output preferences could not be shown.")
                }
            }
        }
    } catch { WindowsNative.update(error.localizedDescription) }
}

/// Apply from the native Voice output dialog, on the UI thread.
func voiceOutputEvent(_ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let voices = WindowsVoiceOutputSettings.voices
    guard voices.indices.contains(Int(index)) else { return }
    holder.enqueueSettings {
        await holder.controller.selectVoiceOutput(voices[Int(index)])
        let saved = await holder.controller.voiceOutputSettings()
        if !WindowsNative.configureVoiceOutput(saved, context: Unmanaged.passUnretained(holder).toOpaque()) {
            WindowsNative.update("The saved voice could not be shown. Reopen Voice and try again.")
        }
    }
}
