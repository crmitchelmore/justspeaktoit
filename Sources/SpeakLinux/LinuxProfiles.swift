import Foundation
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

struct LinuxRecordingSettings: Sendable {
    let modelIndex: Int
    let deviceID: String
    let profile: DesktopProfileSession
    let textOutput: LinuxTextOutputOptions
}

func linuxProfilesEvent(_ payload: String, holder: LinuxEventContext) {
    holder.enqueueSettings {
        do {
            let presentation = try await holder.controller.profileEditorEvent(payload)
            guard jsti_profiles_set(presentation, 1) == 0 else {
                throw DesktopHostError(message: "Profiles could not be displayed. Reopen Profiles.")
            }
        } catch {
            if jsti_profiles_set(error.localizedDescription, 0) != 0 {
                LinuxHostPlatform.update(error.localizedDescription)
            }
        }
    }
}
