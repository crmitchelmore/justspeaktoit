import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopNativeWindowPlatform {
    func presentProfileList(_ draft: DesktopHostVoiceProfileDraft) {
        showVoiceProfile(draft, phase: 7, status: "")
        do {
            for profile in try loadVoiceProfiles() {
                showVoiceProfile(draft, phase: 6, status: profile.id.uuidString, transcript: profile.name)
            }
        } catch {
            showVoiceProfile(draft, phase: -1, status: error.localizedDescription)
        }
    }

    func manageVoiceProfile(_ command: DesktopVoiceProfileCommand, draft: DesktopHostVoiceProfileDraft) throws {
        guard let id = UUID(uuidString: command.reference), let profile = try voiceProfiles.profile(id: id) else {
            draft.deletion = nil
            throw DesktopHostError(message: "Choose a saved voice profile.")
        }
        if command.operation == .inspectDeletion {
            draft.deletion = profile
            let remote = profile.remoteBindings.map { "\($0.providerDisplayName): \($0.remoteVoiceID)" }
            var summary = "Delete “\(profile.name)” and its local reference clips, embeddings and bindings?"
            if !remote.isEmpty {
                summary += "\nThese remote voices remain at their providers:\n" + remote.joined(separator: "\n")
            }
            showVoiceProfile(draft, phase: 8, status: summary, transcript: id.uuidString)
        } else {
            guard draft.deletion == profile else { throw DesktopHostError(message: "Review this profile again.") }
            draft.deletion = nil
            _ = try deleteVoiceProfile(id: id)
            presentProfileList(draft)
            showVoiceProfile(draft, status: "Deleted “\(profile.name)” from this device.")
        }
    }
}
