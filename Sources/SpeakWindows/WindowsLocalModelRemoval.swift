import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

extension WindowsAppController {
    /// Refuses a model in use, whichever model the app has selected. Otherwise
    /// deletes it and frees the runtime's cache off this actor, so a running
    /// recognition cannot hold up cancellation, recording or settings.
    func removeLocalModel(_ spec: WindowsModelSpec) {
        if localModelInUse(spec.catalogueID) {
            update("\(spec.displayName) is in use. Remove it after the current recording finishes.")
            return
        }
        // Ignored while a download or an earlier removal owns this model's files.
        guard localModels.ownership.beginRemoval(spec.catalogueID) else { return }
        let installer = localInstaller
        let item = LocalModelInstaller.Item(spec)
        let file = installer.fileURL(for: item)
        let teardown = localModels.teardown
        let runtime = localModels.runtime
        // Shutdown waits for the files to go; the settings queue does not.
        activeOperations += 1
        Task { [self] in
            // The runtime closed the file once loaded, so it can go first. Another
            // recognition may replace this model while the job waits; the runtime
            // then keeps that one, checking what it holds under its own lock.
            let failure = await teardown.remove(
                { try installer.remove(item) }, release: { _ = runtime?.releaseModel(loadedFrom: file) }
            )
            finishRemoval(spec, failure: failure)
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

    private func finishRemoval(_ spec: WindowsModelSpec, failure: String?) {
        localModels.ownership.endRemoval(spec.catalogueID)
        if let failure {
            update("\(spec.displayName) could not be removed: \(failure)")
        } else {
            update("\(spec.displayName) removed from this PC.")
        }
        publishLocalModels()
        finishOperation()
    }
}
