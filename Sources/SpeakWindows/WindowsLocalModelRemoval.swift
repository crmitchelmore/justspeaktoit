import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

extension WindowsAppController {
    /// Holds an on-device model for one recording or transcription until
    /// `endLocalUse`, so it cannot be removed meanwhile. Nil for other models.
    func beginLocalUse(_ model: String) -> String? {
        guard let spec = DesktopLocalTranscription.model(for: model, host: .windows) else { return nil }
        localModels.ownership.beginUse(spec.catalogueID)
        return spec.catalogueID
    }

    func endLocalUse(_ model: String?) {
        if let model { localModels.ownership.endUse(model) }
    }

    /// Refuses a model in use, whichever model the app has selected. Otherwise
    /// deletes it and frees the runtime's cache off this actor, so a running
    /// recognition cannot hold up cancellation, recording or settings.
    func removeLocalModel(_ spec: WindowsModelSpec) {
        if localModelInUse(spec.catalogueID) {
            update("\(spec.displayName) is in use. Remove it after the current recording finishes.")
            return
        }
        // Ignored while a download or an earlier removal owns this model's files.
        guard let removal = localModels.ownership.beginRemoval(spec.catalogueID) else { return }
        let installer = localInstaller
        let item = LocalModelInstaller.Item(spec)
        let teardown = localModels.teardown
        // Freed only when the runtime may hold this model, so another stays cached.
        let runtime = removal.freesRuntime ? localModels.runtime : nil
        // Shutdown waits for the files to go; the settings queue does not.
        activeOperations += 1
        Task { [self] in
            let failure = await teardown.remove({ try installer.remove(item) }, release: { runtime?.releaseModel() })
            finishRemoval(spec, removal: removal, failure: failure)
        }
        update("Removing \(spec.displayName)\u{2026}")
        publishLocalModels()
    }

    /// The model a recording will be transcribed with, which a profile may
    /// choose, is in use, as is every model a transcription holds.
    private func localModelInUse(_ model: String) -> Bool {
        let recorded = recording.flatMap {
            DesktopLocalTranscription.model(for: $0.record.modelIdentifier, host: .windows)
        }
        return recorded?.catalogueID == model || localModels.ownership.isInUse(model)
    }

    private func finishRemoval(_ spec: WindowsModelSpec, removal: LocalModelOwnership.Removal, failure: String?) {
        localModels.ownership.endRemoval(removal)
        if let failure {
            update("\(spec.displayName) could not be removed: \(failure)")
        } else {
            update("\(spec.displayName) removed from this PC.")
        }
        publishLocalModels()
        finishOperation()
    }
}
