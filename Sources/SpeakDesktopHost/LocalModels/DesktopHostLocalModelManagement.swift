import Foundation
import SpeakCore
import SpeakDesktop

// Local models' downloads and controls, shared by every host with a local
// runtime. Readiness and recognition live in DesktopHostLocalModelHost.swift.
extension DesktopHostController where Platform: DesktopHostLocalModelPlatform {
    /// Shows Local models from now on. `presenter` is handed back to the platform on every update.
    package func configureLocalModels(presenter: UnsafeMutableRawPointer? = nil) {
        localModels.presenting = true
        localModels.presenter = presenter
        publishLocalModels()
    }

    package func localModelAction(_ action: DesktopHostLocalModelAction, index: Int) {
        guard !closed else { return }
        let models = localModelSpecs
        guard models.indices.contains(index) else { return }
        let spec = models[index]
        switch action {
        case .download: startDownload(spec)
        case .cancel: localModels.downloads[spec.catalogueID]?.cancel()
        case .remove: removeLocalModel(spec)
        }
    }

    /// The GPU choice applies when the runtime next loads.
    package func setLocalUseGPU(_ enabled: Bool) {
        guard !closed else { return }
        settings.localUseGPU = enabled
        saveSettingsQuietly()
        update(localModels.runtime == nil ? "GPU preference saved."
            : "GPU preference saved. It applies after you restart Just Speak to It.")
        publishLocalModels()
    }

    private func startDownload(_ spec: WhisperCppModel) {
        // A download or a removal already running for this model owns its files.
        guard localModels.ownership.beginDownload(spec.catalogueID) else { return }
        let installer = localInstaller
        let identifier = spec.catalogueID
        let item = LocalModelInstaller.Item(spec)
        localModels.progress[identifier] = 0
        activeOperations += 1
        localModels.downloads[identifier] = Task { [self] in
            do {
                try await installer.install(item) { received, _ in
                    Task { await self.localProgress(identifier, received: received) }
                }
                finishDownload(spec, failure: nil)
            } catch is CancellationError {
                finishDownload(spec, failure: "Download paused. Choose Resume download to continue.")
            } catch {
                finishDownload(spec, failure: error.localizedDescription)
            }
        }
        update("Downloading \(spec.displayName) (\(Self.megabytes(spec.artifact.byteCount)))\u{2026}")
        publishLocalModels()
    }

    private func localProgress(_ identifier: String, received: Int64) {
        guard localModels.downloads[identifier] != nil else { return }
        guard let total = localModelSpec(for: identifier)?.artifact.byteCount else { return }
        let previous = localModels.progress[identifier] ?? 0
        // Progress hops arrive as separate tasks; never move backwards.
        guard received > previous else { return }
        localModels.progress[identifier] = received
        // One refresh per whole percent keeps the UI thread idle during large downloads.
        if received * 100 / max(total, 1) != previous * 100 / max(total, 1) { publishLocalModels() }
    }

    private func finishDownload(_ spec: WhisperCppModel, failure: String?) {
        defer { finishOperation() }
        localModels.ownership.endDownload(spec.catalogueID)
        localModels.downloads[spec.catalogueID] = nil
        localModels.progress[spec.catalogueID] = nil
        if spec.catalogueID.hasPrefix(HuggingFaceWhisperModel.identifierPrefix) {
            localModels.importStatus = failure.map { "\(spec.displayName): \($0)" }
                ?? "\(spec.displayName) downloaded and verified. \(Platform.localModelChoiceHint)"
        }
        if let failure {
            update("\(spec.displayName): \(failure)")
        } else {
            update("\(spec.displayName) downloaded and verified. \(Platform.localModelChoiceHint)")
        }
        publishLocalModels()
    }

    private func saveSettingsQuietly() {
        do {
            let url = directory.appendingPathComponent("settings.json")
            try effects.writeSettings(JSONEncoder().encode(settings), to: url)
        } catch { update("Could not save settings: \(error.localizedDescription)") }
    }

}
