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
        return configured && configureVoiceSources(context: context)
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

    static func importVoiceText(path: String, requestID: String, controller: WindowsAppController) async {
        await controller.importVoiceText(path: path, requestID: requestID) {
            voiceTextImported($0, requestID: requestID)
        }
    }
}

// swiftlint:disable:next function_parameter_count
func windowsVoiceSourceEvent(
    _ action: Int32, _ source: Int32, _ text: UnsafePointer<CChar>?,
    _ record: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
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
    } catch { WindowsNative.update(error.localizedDescription) }
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
