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
