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

    package static func needsOnboardingBeforeLaunch(in directory: URL) throws -> Bool {
        let existing = FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path)
        let state = try readState(in: directory, hasExistingSettings: existing)
        return !state.hasCompletedOnboarding
    }

    fileprivate static func readState(
        in directory: URL, hasExistingSettings: Bool = false
    ) throws -> DesktopOnboardingState {
        let url = stateURL(in: directory)
        let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        return DesktopOnboardingState.load(stateData: data, hasExistingSettings: hasExistingSettings)
    }

    fileprivate static func advancing(
        _ state: DesktopOnboardingState, to step: DesktopOnboardingStep, preservingCompletion: Bool = false
    ) -> DesktopOnboardingState {
        var changed = state
        changed.lastStep = step
        changed.hasCompletedOnboarding = state.hasCompletedOnboarding || preservingCompletion || step == .done
        return changed
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
        (try? readOnboardingState()) ?? DesktopOnboardingState()
    }

    package func readOnboardingState() throws -> DesktopOnboardingState {
        try DesktopHostOnboarding.readState(in: directory)
    }

    package func needsOnboarding() -> Bool { !closed && !onboardingState().hasCompletedOnboarding }

    /// Remembers the step reached; reaching Done completes the guide.
    package func recordOnboardingStep(_ step: DesktopOnboardingStep) {
        saveOnboarding(DesktopHostOnboarding.advancing(onboardingState(), to: step))
    }

    package func persistOnboardingStep(
        _ step: DesktopOnboardingStep, preservingCompletion: Bool = false,
        checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        guard !closed else { throw DesktopHostError(message: "Setup cannot be saved after the app closes.") }
        let state = try readOnboardingState()
        try persistOnboardingState(
            DesktopHostOnboarding.advancing(state, to: step, preservingCompletion: preservingCompletion),
            checkCancellation: checkCancellation
        )
    }

    /// Finish or Skip: the guide does not open by itself again.
    package func completeOnboarding() {
        saveOnboarding(DesktopOnboardingState(hasCompletedOnboarding: true, lastStep: .done))
    }

    private func saveOnboarding(_ state: DesktopOnboardingState) {
        guard !closed else { return }
        do {
            // Preserve legacy callers; revision-aware guides use the checked entry points.
            try persistOnboardingState(state, checkCancellation: {})
        } catch { update("Could not save setup progress: \(error.localizedDescription)") }
    }

    /// Native guides acknowledge navigation/completion only after this write.
    package func persistOnboardingState(
        _ state: DesktopOnboardingState,
        checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        guard !closed else { throw DesktopHostError(message: "Setup cannot be saved after the app closes.") }
        try effects.writeSettings(state.encoded(), to: DesktopHostOnboarding.stateURL(in: directory))
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
