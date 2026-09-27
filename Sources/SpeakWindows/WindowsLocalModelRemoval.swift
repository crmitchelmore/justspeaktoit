import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

extension WindowsAppController {
    /// Holds an on-device model for one recording or transcription until
    /// `endLocalUse`, so it cannot be removed meanwhile. Nil for other models.
    func beginLocalUse(_ model: String) -> String? {
        guard let spec = DesktopLocalTranscription.downloadedModel(for: model, host: .windows) else { return nil }
        localModels.ownership.beginUse(spec.catalogueID)
        return spec.catalogueID
    }

    func endLocalUse(_ model: String?) {
        if let model { localModels.ownership.endUse(model) }
    }

    /// Refuses a model in use, whichever model the app has selected. Otherwise
    /// deletes it and frees the runtime's cache off this actor, so a running
    /// recognition cannot hold up cancellation, recording or settings.
    func removeLocalModel(_ spec: WindowsModelSpec) { removeLocalModel(.speech(spec)) }

    func removeLocalModel(_ spec: WindowsLocalModelEntry) {
        if localModelInUse(spec.identifier) {
            update("\(spec.displayName) is in use. Remove it after the current recording finishes.")
            return
        }
        let installer = localInstaller
        let item = spec.item
        // An import that was never downloaded is simply forgotten.
        if spec.isImport, installer.state(of: item) == .notInstalled,
           !localModels.ownership.isDownloading(spec.identifier) {
            forgetImport(spec.identifier)
            update("\(spec.displayName) removed from Local models.")
            publishLocalModels()
            return
        }
        // Ignored while a download or an earlier removal owns this model's files.
        guard localModels.ownership.beginRemoval(spec.identifier) else { return }
        let file = installer.fileURL(for: item)
        let teardown = localModels.teardown
        let speechRuntime = localModels.runtime
        let languageRuntime = localModels.languageRuntime
        let isSpeech: Bool
        if case .speech = spec { isSpeech = true } else { isSpeech = false }
        // Shutdown waits for the files to go; the settings queue does not.
        activeOperations += 1
        Task { [self] in
            // The runtime closed the file once loaded, so it can go first. Another
            // recognition may replace this model while the job waits; the runtime
            // then keeps that one, checking what it holds under its own lock.
            let failure = await teardown.remove({ try installer.remove(item) }, release: {
                if isSpeech {
                    _ = speechRuntime?.releaseModel(loadedFrom: file)
                } else {
                    _ = languageRuntime?.releaseModel(loadedFrom: file)
                }
            })
            finishRemoval(spec, failure: failure)
        }
        update("Removing \(spec.displayName)\u{2026}")
        publishLocalModels()
    }

    /// The model a recording will be transcribed with, which a profile may
    /// choose, is in use, as is every model a transcription holds.
    private func localModelInUse(_ model: String) -> Bool {
        let recorded = recording.flatMap {
            DesktopLocalTranscription.downloadedModel(for: $0.record.modelIdentifier, host: .windows)
        }
        return recorded?.catalogueID == model || localModels.ownership.isInUse(model)
    }

    private func finishRemoval(_ spec: WindowsLocalModelEntry, failure: String?) {
        localModels.ownership.endRemoval(spec.identifier)
        if let failure {
            update("\(spec.displayName) could not be removed: \(failure)")
        } else {
            if spec.isImport { forgetImport(spec.identifier) }
            update("\(spec.displayName) removed from this PC.")
        }
        publishLocalModels()
        configurePostProcessingControls()
        finishOperation()
    }
}
