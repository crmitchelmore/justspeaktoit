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

extension DesktopHostController {
    package func hotKeySettings() -> Platform.HotKeySettings { settings.hotKey ?? Platform.defaultHotKey }
}
