import Foundation
import SpeakCore
import SpeakDesktop

// Downloads, verification, readiness and recognition of on-device models,
// shared by every host with a local runtime. Moved from the Windows host.
extension DesktopHostController where Platform: DesktopHostLocalModelPlatform {
    package static var localModelsFolder: String { "LocalModels" }

    /// The on-device models this host offers, in catalogue order.
    package var localModelSpecs: [WhisperCppModel] { DesktopLocalTranscription.models(host: Platform.localModelHost) }

    package var localInstaller: LocalModelInstaller {
        let root = directory.appendingPathComponent(Self.localModelsFolder, isDirectory: true)
        return LocalModelInstaller(
            root: root, digests: Platform.localModelDigests, transport: Platform.localModelTransport,
            prepareDirectory: { url in
                // Both levels are private to the user; a model folder's parent must exist first.
                for folder in [root, url] { try Platform.preparePrivateDirectory(folder) }
            }
        )
    }

    package var localUseGPU: Bool { settings.localUseGPU ?? true }

    /// Why an on-device model cannot run now, or nil when it can.
    package func localReadiness(_ model: String) -> String? {
        guard let spec = DesktopLocalTranscription.model(for: model, host: Platform.localModelHost) else {
            return "This on-device model is not available in this \(Platform.displayName) build."
        }
        if localModels.ownership.isRemoving(spec.catalogueID) {
            return "\(spec.displayName) is being removed from \(Platform.localDeviceName)."
        }
        if let missing = Platform.localRuntimeMissing { return missing }
        if let failure = localModels.runtimeFailure { return failure }
        guard localInstaller.state(of: .init(spec)) == .installed else {
            return "\(spec.displayName) is not downloaded yet. Open Local models to download it."
        }
        return nil
    }

    /// Loads the runtime once, off the actor.
    package func localRuntime() async throws -> Platform.LocalRuntime {
        if let runtime = localModels.runtime { return runtime }
        let allowGPU = localUseGPU
        do {
            let runtime = try await Task.detached { try Platform.openLocalRuntime(allowGPU: allowGPU) }.value
            localModels.runtime = runtime
            publishLocalModels()
            return runtime
        } catch {
            localModels.runtimeFailure = "The on-device speech runtime could not start: \(error.localizedDescription)"
            publishLocalModels()
            throw error
        }
    }

    package func transcribeLocally(_ audio: URL, model: String, language: String?) async throws -> TranscriptionResult {
        guard let spec = DesktopLocalTranscription.model(for: model, host: Platform.localModelHost) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        if let problem = localReadiness(model) { throw DesktopHostError(message: problem) }
        // Checked and held together: no removal can start before recognition ends.
        let used = beginLocalUse(model)
        defer { endLocalUse(used) }
        // The runtime reads the file only when it loads it, so its bytes are
        // rehashed before any recognition that may load them.
        let (file, identity) = try await localModelVerifiedForLoading(spec)
        let runtime = try await localRuntime()
        update(
            "Transcribing on \(Platform.localDeviceName) with \(spec.displayName)\u{2026} "
                + "Your recording is saved locally.",
            state: 2
        )
        let result = try await DesktopLocalTranscription.transcribe(
            audioURL: audio, model: spec, modelFile: file, language: language, recognizer: runtime.recognizer
        )
        try await confirmLocalModelUnchanged(spec, file: file, identity: identity)
        return result
    }

    // MARK: - Local models

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
        let total = DesktopLocalTranscription.model(for: identifier, host: Platform.localModelHost)?
            .artifact.byteCount ?? 1
        let previous = localModels.progress[identifier] ?? 0
        // Progress hops arrive as separate tasks; never move backwards.
        guard received > previous else { return }
        localModels.progress[identifier] = received
        // One refresh per whole percent keeps the UI thread idle during large downloads.
        if received * 100 / max(total, 1) != previous * 100 / max(total, 1) { publishLocalModels() }
    }

    private func finishDownload(_ spec: WhisperCppModel, failure: String?) {
        localModels.ownership.endDownload(spec.catalogueID)
        // New bytes are hashed again before the runtime loads them.
        localModels.loadVerification.forget(localInstaller.fileURL(for: .init(spec)))
        localModels.downloads[spec.catalogueID] = nil
        localModels.progress[spec.catalogueID] = nil
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

    /// The runtime line shown in Local models.
    package var localRuntimeStatus: String {
        let models = localModelSpecs
        let installer = localInstaller
        let downloaded = models.filter { installer.state(of: .init($0)) == .installed }.count
        let counts = "\(downloaded) of \(models.count) on-device models downloaded."
        if let failure = localModels.runtimeFailure { return failure + " " + counts }
        guard Platform.localRuntimeMissing == nil else {
            return "The on-device speech runtime (whisper.cpp) is not included in this build. " + counts
        }
        if let runtime = localModels.runtime { return "On-device: \(runtime.description). " + counts }
        return Platform.localRuntimeSummary(useGPU: localUseGPU) + " " + counts
    }

    /// Presents every row, and refreshes the picker when a model's state label changed.
    package func publishLocalModels() {
        guard !closed, localModels.presenting else { return }
        let installer = localInstaller
        var labels: [String: String] = [:]
        var rows: [DesktopHostLocalModelRow] = []
        for spec in localModelSpecs {
            let (row, label) = localModelRow(spec, installer: installer)
            rows.append(row)
            labels[spec.catalogueID] = label
        }
        if labels != DesktopHostModels.labelledSnapshot.1 {
            DesktopHostModels.setLocalLabels(labels)
            publishModelCatalog(modelCatalog.snapshot)
        }
        Platform.presentLocalModels(
            rows, status: localRuntimeStatus, useGPU: localUseGPU, presenter: localModels.presenter
        )
    }

    /// One model's row in Local models, and the state shown after its name in
    /// the model picker unless it is simply downloaded.
    private func localModelRow(
        _ spec: WhisperCppModel, installer: LocalModelInstaller
    ) -> (row: DesktopHostLocalModelRow, label: String?) {
        let size = Self.megabytes(spec.artifact.byteCount)
        let state: DesktopHostLocalModelRow.State
        let detail: String
        var label: String?
        if let received = localModels.progress[spec.catalogueID], localModels.downloads[spec.catalogueID] != nil {
            state = .downloading
            detail = "Downloading \(received * 100 / max(spec.artifact.byteCount, 1))% of \(size)"
            label = "downloading"
        } else if localModels.ownership.isRemoving(spec.catalogueID) {
            state = .removing
            detail = "\(size) \u{00B7} Removing\u{2026}"
            label = "removing"
        } else {
            switch installer.state(of: .init(spec)) {
            case .installed:
                state = .downloaded
                detail = "\(size) \u{00B7} Downloaded and verified"
            case .partial(let received, let total):
                state = .paused
                detail = "\(size) \u{00B7} \(received * 100 / max(total, 1))% downloaded, paused"
                label = "download paused"
            case .notInstalled:
                state = .notDownloaded
                detail = "\(size) \u{00B7} Not downloaded"
                label = "download in Local models"
            }
        }
        let about = "\(spec.summary) Whisper weights (\(spec.quantization), \(spec.artifact.license) licence) "
            + "from huggingface.co/\(WhisperCppModels.repository), pinned by SHA-256 "
            + "\(spec.artifact.sha256.prefix(12))\u{2026} and verified after download."
        return (DesktopHostLocalModelRow(name: spec.displayName, detail: detail, about: about, state: state), label)
    }

    package static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_048_576).rounded())) MB"
    }
}
