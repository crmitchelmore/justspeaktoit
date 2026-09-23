import Foundation
import SpeakWindowsPlatform
import CWindowsSupport

extension WindowsNative {
    /// The choices the native Text output dialog opens with. Valid before the
    /// window runs and from any thread afterwards.
    static func configureTextOutput(_ options: WindowsTextOutputOptions, context: UnsafeMutableRawPointer) throws {
        let choice = options.nativeChoice
        guard jsti_window_set_text_output(
            choice.method, choice.insertion, choice.restoreClipboard, textOutputEvent, context
        ) == 0 else { throw WindowsNativeError(message: "Could not configure text output controls.") }
    }
}

/// Atomic Apply from the native dialog, on the UI thread. Saving joins the
/// settings queue, so a recording started after this Apply waits for it and
/// uses it. The dialog is then refreshed from what was actually saved, so a
/// reopened dialog never shows a choice that failed to save.
func textOutputEvent(_ method: Int32, _ insertion: Int32, _ restore: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let choice = WindowsTextOutputOptions(
        nativeChoice: WindowsTextOutputNativeChoice(method: method, insertion: insertion, restoreClipboard: restore)
    )
    holder.enqueueSettings {
        if let choice {
            await holder.controller.saveTextOutput(choice)
        } else {
            WindowsNative.update("The text output choice could not be read. Reopen Text output and try again.")
        }
        let saved = await holder.controller.textOutputOptions()
        do {
            try WindowsNative.configureTextOutput(saved, context: Unmanaged.passUnretained(holder).toOpaque())
        } catch { WindowsNative.update(error.localizedDescription) }
    }
}

extension WindowsAppController {
    /// Persisted choices, or the defaults. Each recording snapshots this when
    /// it starts.
    func textOutputOptions() -> WindowsTextOutputOptions { settings.textOutput ?? .init() }

    /// Writes a copy of every setting atomically and publishes the change only
    /// once saved, so a failed write leaves all settings as they were.
    func saveTextOutput(_ options: WindowsTextOutputOptions) {
        guard !closed else { return }
        var changed = settings
        changed.textOutput = options
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            // Recording and transcription keep the status line until they finish.
            guard !busy, recording == nil else { return }
            update(Self.savedStatus(options))
        } catch { update("Could not save text output settings: \(error.localizedDescription)") }
    }

    private static func savedStatus(_ options: WindowsTextOutputOptions) -> String {
        switch options.method {
        case .smart:
            return "Text output saved: Smart inserts directly, or uses a guarded clipboard paste when needed."
        case .directOnly:
            return "Text output saved: direct insertion only; the clipboard is never used."
        case .clipboardOnly:
            return "Text output saved: finished recordings are copied to the clipboard."
        }
    }
}
