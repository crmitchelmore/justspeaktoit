import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// The controller's on-device models state: running downloads, their
/// progress, model ownership and the whisper.cpp runtime once loaded.
struct LinuxLocalModelsState {
    var downloads: [String: Task<Void, Never>] = [:]
    var progress: [String: Int64] = [:]
    var runtime: LinuxWhisperRuntime?
    var runtimeFailure: String?
    /// Set once the window can show the On-device models group.
    var published = false
    var ownership = LocalModelOwnership()
    /// Deletes removed models and frees the runtime's cache off the actor.
    let teardown = LocalModelTeardown()
}

/// One model's row in the On-device models group.
struct LinuxLocalModelRow {
    let name: String
    let detail: String
    let about: String
    let state: Int32
}

enum LinuxLocalModels {
    static let folder = "LocalModels"

    /// The catalogue's whisper.cpp models, in the model picker as on Windows.
    static var options: [ModelCatalog.Option] { DesktopLocalTranscription.options(host: .linux) }

    static var models: [WhisperCppModel] { DesktopLocalTranscription.models(host: .linux) }

    static func megabytes(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1_048_576).rounded())) MB" }
}

extension LinuxAppController {
    var localInstaller: LocalModelInstaller {
        let root = directory.appendingPathComponent(LinuxLocalModels.folder, isDirectory: true)
        return LocalModelInstaller(
            root: root, digests: LinuxSHA256Hasher.provider, transport: LocalModelURLSessionTransport(),
            prepareDirectory: { url in
                for folder in [root, url] { try LinuxFiles.preparePrivateDirectory(folder) }
            }
        )
    }

    var localUseGPU: Bool { settings.localUseGPU ?? true }

    /// Why an on-device model cannot run now, or nil when it can.
    func localReadiness(_ model: String) -> String? {
        guard let spec = DesktopLocalTranscription.model(for: model, host: .linux) else {
            return "This on-device model is not available in this Linux build."
        }
        if localModels.ownership.isRemoving(spec.catalogueID) {
            return "\(spec.displayName) is being removed from this computer."
        }
        guard LinuxWhisperRuntime.isInstalled() else {
            return "This build does not include the on-device speech runtime (whisper.cpp). Use the Flatpak, "
                + "or set JSTI_WHISPER_LIBRARY_DIR to a whisper.cpp 1.9.4 build."
        }
        if let failure = localModels.runtimeFailure { return failure }
        guard localInstaller.state(of: .init(spec)) == .installed else {
            return "\(spec.displayName) is not downloaded yet. Download it under On-device models."
        }
        return nil
    }

    /// Loads the runtime once, off the actor.
    func localRuntime() async throws -> LinuxWhisperRuntime {
        if let runtime = localModels.runtime { return runtime }
        let allowGPU = localUseGPU
        do {
            let runtime = try await Task.detached { try LinuxWhisperRuntime.open(allowGPU: allowGPU) }.value
            localModels.runtime = runtime
            publishLocalModels()
            return runtime
        } catch {
            localModels.runtimeFailure = "The on-device speech runtime could not start: \(error.localizedDescription)"
            publishLocalModels()
            throw error
        }
    }

    func transcribeLocally(_ audio: URL, model: String, language: String?) async throws -> TranscriptionResult {
        guard let spec = DesktopLocalTranscription.model(for: model, host: .linux) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        if let problem = localReadiness(model) { throw DesktopHostError(message: problem) }
        // Checked and held together: no removal can start before recognition ends.
        let used = holdLocalModel(model)
        defer { releaseLocalModel(used) }
        let file = try localInstaller.verifiedFile(for: .init(spec))
        let runtime = try await localRuntime()
        update(
            "Transcribing on this computer with \(spec.displayName)\u{2026} Your recording is saved locally.", state: 2
        )
        return try await DesktopLocalTranscription.transcribe(
            audioURL: audio, model: spec, modelFile: file, language: language,
            recognizer: LinuxWhisperRecognizer(runtime: runtime)
        )
    }

    /// Holds an on-device model until `releaseLocalModel`, so it cannot be
    /// removed meanwhile. Nil for other models.
    func holdLocalModel(_ model: String) -> String? {
        guard let spec = DesktopLocalTranscription.model(for: model, host: .linux) else { return nil }
        localModels.ownership.beginUse(spec.catalogueID)
        return spec.catalogueID
    }

    func releaseLocalModel(_ model: String?) {
        if let model { localModels.ownership.endUse(model) }
    }

    // MARK: - On-device models group

    func localModelAction(_ action: String, index: Int) {
        guard !closed else { return }
        let models = LinuxLocalModels.models
        guard models.indices.contains(index) else { return }
        let spec = models[index]
        switch action {
        case "download": startDownload(spec)
        case "cancel": localModels.downloads[spec.catalogueID]?.cancel()
        case "remove": removeLocalModel(spec)
        default: break
        }
    }

    func setLocalUseGPU(_ enabled: Bool) {
        guard !closed, enabled != localUseGPU else { return }
        var changed = settings
        changed.localUseGPU = enabled
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            update(localModels.runtime == nil ? "GPU preference saved."
                : "GPU preference saved. It applies after you restart Just Speak to It.")
        } catch { update("Could not save settings: \(error.localizedDescription)") }
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
                finishDownload(spec, failure: "Download paused. Choose Resume to continue.")
            } catch {
                finishDownload(spec, failure: error.localizedDescription)
            }
        }
        update("Downloading \(spec.displayName) (\(LinuxLocalModels.megabytes(spec.artifact.byteCount)))\u{2026}")
        publishLocalModels()
    }

    private func localProgress(_ identifier: String, received: Int64) {
        guard localModels.downloads[identifier] != nil else { return }
        let total = DesktopLocalTranscription.model(for: identifier, host: .linux)?.artifact.byteCount ?? 1
        let previous = localModels.progress[identifier] ?? 0
        guard received > previous else { return }
        localModels.progress[identifier] = received
        // One refresh per whole percent keeps the GTK thread idle.
        if received * 100 / max(total, 1) != previous * 100 / max(total, 1) { publishLocalModels() }
    }

    private func finishDownload(_ spec: WhisperCppModel, failure: String?) {
        localModels.ownership.endDownload(spec.catalogueID)
        localModels.downloads[spec.catalogueID] = nil
        localModels.progress[spec.catalogueID] = nil
        if let failure {
            update("\(spec.displayName): \(failure)")
        } else {
            update("\(spec.displayName) downloaded and verified. Choose it in the model list.")
        }
        publishLocalModels()
    }

    /// Refuses a model in use. Otherwise deletes it and frees the runtime's
    /// cache off this actor, so a running recognition cannot hold anything up.
    private func removeLocalModel(_ spec: WhisperCppModel) {
        let recorded = recording.flatMap {
            DesktopLocalTranscription.model(for: $0.record.modelIdentifier, host: .linux)
        }
        if recorded?.catalogueID == spec.catalogueID || localModels.ownership.isInUse(spec.catalogueID) {
            update("\(spec.displayName) is in use. Remove it after the current recording finishes.")
            return
        }
        guard localModels.ownership.beginRemoval(spec.catalogueID) else { return }
        let installer = localInstaller
        let item = LocalModelInstaller.Item(spec)
        let file = installer.fileURL(for: item)
        let teardown = localModels.teardown
        let runtime = localModels.runtime
        activeOperations += 1
        Task { [self] in
            let failure = await teardown.remove(
                { try installer.remove(item) }, release: { _ = runtime?.releaseModel(loadedFrom: file) }
            )
            finishRemoval(spec, failure: failure)
        }
        update("Removing \(spec.displayName)\u{2026}")
        publishLocalModels()
    }

    private func finishRemoval(_ spec: WhisperCppModel, failure: String?) {
        localModels.ownership.endRemoval(spec.catalogueID)
        if let failure {
            update("\(spec.displayName) could not be removed: \(failure)")
        } else {
            update("\(spec.displayName) removed from this computer.")
        }
        publishLocalModels()
        finishOperation()
    }

    /// The runtime line shown in the group.
    var localRuntimeStatus: String {
        let models = LinuxLocalModels.models
        let installer = localInstaller
        let downloaded = models.filter { installer.state(of: .init($0)) == .installed }.count
        let counts = "\(downloaded) of \(models.count) on-device models downloaded."
        if let failure = localModels.runtimeFailure { return failure + " " + counts }
        guard LinuxWhisperRuntime.isInstalled() else {
            return "The on-device speech runtime (whisper.cpp) is not included in this build. " + counts
        }
        if let runtime = localModels.runtime { return "On-device: \(runtime.description). " + counts }
        let gpu = localUseGPU ? "a Vulkan GPU when available, otherwise the CPU" : "the CPU"
        return "On-device with whisper.cpp 1.9.4 using \(gpu). Audio stays on this computer. " + counts
    }

    func configureLocalModels() {
        localModels.published = true
        publishLocalModels()
    }

    func publishLocalModels() {
        guard !closed, localModels.published else { return }
        let installer = localInstaller
        var labels: [String: String] = [:]
        var rows: [LinuxLocalModelRow] = []
        for spec in LinuxLocalModels.models {
            let (row, label) = localModelRow(spec, installer: installer)
            rows.append(row)
            labels[spec.catalogueID] = label
        }
        DesktopHostModels.setLocalLabels(labels)
        publishModelCatalog(modelCatalog.snapshot)
        let strings = LinuxWindow.Strings()
        let native = rows.map {
            JSTILocalModelRow(
                name: strings.add($0.name), detail: strings.add($0.detail), about: strings.add($0.about),
                state: $0.state
            )
        }
        let status = localRuntimeStatus
        withExtendedLifetime(strings) {
            _ = native.withUnsafeBufferPointer {
                jsti_window_set_local_models($0.baseAddress, $0.count, status, localUseGPU ? 1 : 0)
            }
        }
    }

    private func localModelRow(
        _ spec: WhisperCppModel, installer: LocalModelInstaller
    ) -> (row: LinuxLocalModelRow, label: String?) {
        let size = LinuxLocalModels.megabytes(spec.artifact.byteCount)
        let state: Int32
        let detail: String
        var label: String?
        if let received = localModels.progress[spec.catalogueID], localModels.downloads[spec.catalogueID] != nil {
            state = Int32(JSTI_LOCAL_MODEL_DOWNLOADING)
            detail = "Downloading \(received * 100 / max(spec.artifact.byteCount, 1))% of \(size)"
            label = "downloading"
        } else if localModels.ownership.isRemoving(spec.catalogueID) {
            state = Int32(JSTI_LOCAL_MODEL_INSTALLED)
            detail = "\(size) \u{00B7} Removing\u{2026}"
            label = "removing"
        } else {
            switch installer.state(of: .init(spec)) {
            case .installed:
                state = Int32(JSTI_LOCAL_MODEL_INSTALLED)
                detail = "\(size) \u{00B7} Downloaded and verified"
            case .partial(let received, let total):
                state = Int32(JSTI_LOCAL_MODEL_PARTIAL)
                detail = "\(size) \u{00B7} \(received * 100 / max(total, 1))% downloaded, paused"
                label = "download paused"
            case .notInstalled:
                state = Int32(JSTI_LOCAL_MODEL_NOT_INSTALLED)
                detail = "\(size) \u{00B7} Not downloaded"
                label = "download under On-device models"
            }
        }
        let about = "\(spec.summary) Whisper weights (\(spec.quantization), \(spec.artifact.license) licence) "
            + "from huggingface.co/\(WhisperCppModels.repository), pinned by SHA-256 "
            + "\(spec.artifact.sha256.prefix(12))\u{2026} and verified after download."
        return (LinuxLocalModelRow(name: spec.displayName, detail: detail, about: about, state: state), label)
    }
}
