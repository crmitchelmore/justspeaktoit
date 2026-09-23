import Foundation
import SpeakDesktopHost
import SpeakLinuxPlatform

extension LinuxAppController {
    /// Persisted choices, or the defaults. Each recording snapshots this when
    /// it starts.
    func textOutputOptions() -> LinuxTextOutputOptions { settings.textOutput ?? .init() }

    /// Writes a copy of every setting atomically and publishes the change only
    /// once saved, so a failed write leaves all settings as they were.
    func saveTextOutput(_ options: LinuxTextOutputOptions) {
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
            update(options.savedStatus)
        } catch { update("Could not save text output settings: \(error.localizedDescription)") }
    }

    var isRecording: Bool { recording != nil }
}
