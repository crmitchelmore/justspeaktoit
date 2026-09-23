import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func selectedMicrophone() -> String { settings.microphoneDeviceID ?? "" }
    package func setMicrophoneWarning(_ warning: String?) { microphoneWarning = warning }

    package func selectMicrophone(_ identifier: String) {
        guard canUseHistory else { return }
        var changed = settings
        changed.microphoneDeviceID = identifier.isEmpty ? nil : identifier
        do {
            try JSONEncoder().encode(changed).write(
                to: directory.appendingPathComponent("settings.json"), options: .atomic
            )
            settings = changed
        } catch { update("Could not save the microphone choice: \(error.localizedDescription)") }
    }
}

/// Shortcut gesture bookkeeping, in the monotonic clock of recognition.
package struct DesktopHostHotKeySessionState: Sendable {
    package var lastDoubleTap: TimeInterval = -.infinity
    /// Starts recognised before this ended while a shortcut stop was finishing.
    package var startsAfter: TimeInterval = 0

    package init() {}
}

extension DesktopHostController {
    /// Ends Read aloud: the current segment stops through the shared playback
    /// controller and no later segment is synthesized.
    package func stopReadAloud() { Platform.stopReadAloud(&readAloudState) }

    package func hotKeySettings() -> Platform.HotKeySettings { settings.hotKey ?? Platform.defaultHotKey }
}
