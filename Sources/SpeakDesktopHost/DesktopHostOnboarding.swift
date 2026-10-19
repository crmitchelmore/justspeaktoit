import Foundation
import SpeakCore

/// First-run guide persistence. State lives in its own small file beside
/// `settings.json`, under the Mac's canonical `hasCompletedOnboarding` key,
/// so saving settings never races the guide and the guide never rewrites
/// settings it does not own.
package enum DesktopHostOnboarding {
    package static func stateURL(in directory: URL) -> URL {
        directory.appendingPathComponent(DesktopOnboardingState.fileName)
    }

    /// Call before the controller is created: an install that already has
    /// settings but no guide state predates the guide, so it is recorded as
    /// onboarded and an upgrade never opens the first-run guide.
    package static func adoptExistingInstall(directory: URL) {
        let manager = FileManager.default
        let state = stateURL(in: directory)
        guard !manager.fileExists(atPath: state.path),
              manager.fileExists(atPath: directory.appendingPathComponent("settings.json").path),
              let data = try? DesktopOnboardingState(hasCompletedOnboarding: true).encoded() else { return }
        try? data.write(to: state, options: .atomic)
    }
}

extension DesktopHostController {
    package func onboardingState() -> DesktopOnboardingState {
        let url = DesktopHostOnboarding.stateURL(in: directory)
        let data = FileManager.default.fileExists(atPath: url.path) ? try? Data(contentsOf: url) : nil
        return DesktopOnboardingState.load(stateData: data, hasExistingSettings: false)
    }

    package func needsOnboarding() -> Bool { !closed && !onboardingState().hasCompletedOnboarding }

    /// Remembers the step reached; reaching Done completes the guide.
    package func recordOnboardingStep(_ step: DesktopOnboardingStep) {
        var state = onboardingState()
        state.lastStep = step
        if step == .done { state.hasCompletedOnboarding = true }
        saveOnboarding(state)
    }

    /// Finish or Skip: the guide does not open by itself again.
    package func completeOnboarding() {
        saveOnboarding(DesktopOnboardingState(hasCompletedOnboarding: true, lastStep: .done))
    }

    private func saveOnboarding(_ state: DesktopOnboardingState) {
        guard !closed else { return }
        do {
            try effects.writeSettings(state.encoded(), to: DesktopHostOnboarding.stateURL(in: directory))
        } catch { update("Could not save setup progress: \(error.localizedDescription)") }
    }

    /// Whether the selected model can transcribe now, in a sentence for the
    /// guide's "Choose how speech becomes text" step.
    package func onboardingRouteSummary() -> (ready: Bool, text: String) {
        let model = settings.model
        let name = DesktopHostModels.all.first { $0.id == model }?.displayName ?? model
        do {
            try requireCredentialOrLocalModel(model)
            return DesktopHostModels.isLocal(model)
                ? (true, "Ready: \(name) runs on this computer.")
                : (true, "Ready: \(name) with your saved key.")
        } catch {
            return (false, "\(name) is selected. \(error.localizedDescription)")
        }
    }

    /// The shortcut hint the ready status uses, for the practice step.
    package func onboardingShortcutHint() -> String { Platform.readyHint(hotKeySettings()) }

    /// The dashboard's permission warning: the ready status names a blocked
    /// essential permission, as the Mac dashboard's permissions section does.
    /// Unlike the microphone list warning it never holds back prewarming.
    package func setPermissionWarning(_ items: [DesktopPermissionItem]) {
        permissionWarning = DesktopPermissionSummary.blockingMessage(items)
    }
}
