import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

/// Saved model choices for the native Source and Mode pickers.
struct WindowsModelPreferences: Sendable {
    let batch: String?
    let live: String?
    let local: String?
}

/// The controller's Local models state: running downloads, their progress and
/// the whisper.cpp runtime once loaded.
struct WindowsLocalModelsState {
    var downloads: [String: Task<Void, Never>] = [:]
    var progress: [String: Int64] = [:]
    var runtime: WindowsWhisperRuntime?
    var runtimeFailure: String?
    var context: UnsafeMutableRawPointer?
    /// The models recordings and transcriptions use, and the downloads and
    /// removals that own model files.
    var ownership = LocalModelOwnership()
    /// Deletes removed models and frees the runtime's cache off the actor.
    let teardown = LocalModelTeardown()
}

extension WindowsAppController {
    static let localModelsFolder = "LocalModels"

    var localInstaller: LocalModelInstaller {
        let root = directory.appendingPathComponent(Self.localModelsFolder, isDirectory: true)
        return LocalModelInstaller(
            root: root, digests: WindowsSHA256Hasher.provider, transport: LocalModelURLSessionTransport(),
            prepareDirectory: { url in
                // Both levels get the app's private ACL; a model folder's parent must exist first.
                for folder in [root, url] {
                    try folder.path.withCString { path in
                        try WindowsNative.checked { jsti_private_directory_prepare(path, $0, $1) }
                    }
                }
            }
        )
    }

    var localUseGPU: Bool { settings.localUseGPU ?? true }

    /// The runtime DLLs live beside the executable in the bundle and MSIX;
    /// developer builds point `JSTI_WHISPER_RUNTIME_DIRECTORY` at a runtime build.
    var localRuntimeBundled: Bool {
        FileManager.default.fileExists(
            atPath: WindowsWhisperRuntime.defaultDirectory.appendingPathComponent("whisper.dll").path
        )
    }

    /// The key a remote model needs, or an empty key after checking that an
    /// on-device model can run. Throws with the user-facing reason otherwise.
    @discardableResult
    func requireCredentialOrLocalModel(_ model: String) throws -> String {
        if WindowsModels.isLocal(model) {
            if let problem = localReadiness(model) { throw WindowsNativeError(message: problem) }
            return ""
        }
        let key = try effects.apiKey(name: credentialIdentifier(for: model))
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        return key
    }

    /// The key for a remote model's batch request; on-device models need none.
    func transcriptionKey(for model: String) throws -> String {
        WindowsModels.isLocal(model) ? "" : try effects.apiKey(name: credentialIdentifier(for: model))
    }

    /// The upload cap is a provider limit; on-device audio never leaves this PC.
    func checkUploadSize(_ audio: URL, model: String) throws {
        guard !WindowsModels.isLocal(model) else { return }
        let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25_000_000 else {
            throw WindowsNativeError(
                message: "Audio exceeds this Windows preview\u{2019}s 25 MB upload cap. The recording is saved."
            )
        }
    }

    func transcribingStatus(for model: String) -> String {
        WindowsModels.isLocal(model) ? "Transcribing on this PC\u{2026} Your recording is saved locally."
            : "Transcribing\u{2026} Your recording is saved locally."
    }

    /// The live, on-device or remote batch slot restores this model when the
    /// user switches Source or Mode again.
    func rememberModelSlot() {
        if WindowsModels.isLive(settings.model) {
            settings.liveModel = settings.model
        } else if WindowsModels.isLocal(settings.model) {
            settings.localModel = settings.model
        } else {
            settings.batchModel = settings.model
        }
    }

    func readyStatus(savedRecordings: Int) throws -> String {
        if WindowsModels.isLocal(settings.model) {
            return localReadiness(settings.model)
                ?? "Ready on this PC. \(hotKeySettings().readyHint) \(savedRecordings) saved recordings."
        }
        let key = try WindowsNative.apiKey(name: credentialIdentifier(for: settings.model))
        return key.isEmpty ? "Enter and save the selected provider\u{2019}s API key to record or import audio."
            : "Ready. \(hotKeySettings().readyHint) \(savedRecordings) saved recordings."
    }

    /// Why an on-device model cannot run now, or nil when it can.
    func localReadiness(_ model: String) -> String? {
        guard let spec = DesktopLocalTranscription.model(for: model, host: .windows) else {
            return "This on-device model is not available in this Windows build."
        }
        if localModels.ownership.isRemoving(spec.catalogueID) {
            return "\(spec.displayName) is being removed from this PC."
        }
        guard localRuntimeBundled else {
            return "This build does not include the on-device speech runtime. Use the Windows bundle or package."
        }
        if let failure = localModels.runtimeFailure { return failure }
        guard localInstaller.state(of: .init(spec)) == .installed else {
            return "\(spec.displayName) is not downloaded yet. Open Local models to download it."
        }
        return nil
    }

    /// Loads the runtime once, off the actor.
    func localRuntime() async throws -> WindowsWhisperRuntime {
        if let runtime = localModels.runtime { return runtime }
        let allowGPU = localUseGPU
        do {
            let runtime = try await Task.detached { try WindowsWhisperRuntime.open(allowGPU: allowGPU) }.value
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
        guard let spec = DesktopLocalTranscription.model(for: model, host: .windows) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        if let problem = localReadiness(model) { throw WindowsNativeError(message: problem) }
        // Checked and held together: no removal can start before recognition ends.
        let used = beginLocalUse(model)
        defer { endLocalUse(used) }
        let file = try localInstaller.verifiedFile(for: .init(spec))
        let runtime = try await localRuntime()
        update("Transcribing on this PC with \(spec.displayName)\u{2026} Your recording is saved locally.", state: 2)
        return try await DesktopLocalTranscription.transcribe(
            audioURL: audio, model: spec, modelFile: file, language: language,
            recognizer: WindowsWhisperRecognizer(runtime: runtime)
        )
    }

    // MARK: - Local models dialog

    func configureLocalModels(context: UnsafeMutableRawPointer) {
        localModels.context = context
        publishLocalModels()
    }

    func localModelAction(_ action: Int32, index: Int) {
        guard !closed else { return }
        let models = DesktopLocalTranscription.models(host: .windows)
        switch action {
        case Int32(JSTI_LOCAL_MODEL_GPU_ON.rawValue), Int32(JSTI_LOCAL_MODEL_GPU_OFF.rawValue):
            settings.localUseGPU = action == Int32(JSTI_LOCAL_MODEL_GPU_ON.rawValue)
            saveSettingsQuietly()
            update(localModels.runtime == nil ? "GPU preference saved."
                : "GPU preference saved. It applies after you restart Just Speak to It.")
            publishLocalModels()
            return
        default: break
        }
        guard models.indices.contains(index) else { return }
        let spec = models[index]
        switch action {
        case Int32(JSTI_LOCAL_MODEL_DOWNLOAD.rawValue): startDownload(spec)
        case Int32(JSTI_LOCAL_MODEL_CANCEL.rawValue):
            localModels.downloads[spec.catalogueID]?.cancel()
        case Int32(JSTI_LOCAL_MODEL_REMOVE.rawValue): removeLocalModel(spec)
        default: break
        }
    }

    private func startDownload(_ spec: WindowsModelSpec) {
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
        let total = DesktopLocalTranscription.model(for: identifier, host: .windows)?.artifact.byteCount ?? 1
        let previous = localModels.progress[identifier] ?? 0
        // Progress hops arrive as separate tasks; never move backwards.
        guard received > previous else { return }
        localModels.progress[identifier] = received
        // One refresh per whole percent keeps the UI thread idle during large downloads.
        if received * 100 / max(total, 1) != previous * 100 / max(total, 1) { publishLocalModels() }
    }

    private func finishDownload(_ spec: WindowsModelSpec, failure: String?) {
        localModels.ownership.endDownload(spec.catalogueID)
        localModels.downloads[spec.catalogueID] = nil
        localModels.progress[spec.catalogueID] = nil
        if let failure {
            update("\(spec.displayName): \(failure)")
        } else {
            update("\(spec.displayName) downloaded and verified. Choose it under Source: Local.")
        }
        publishLocalModels()
    }

    private func saveSettingsQuietly() {
        do {
            let url = directory.appendingPathComponent("settings.json")
            try effects.writeSettings(JSONEncoder().encode(settings), to: url)
        } catch { update("Could not save settings: \(error.localizedDescription)") }
    }

    /// The runtime line shown in the dialog and under the model picker.
    var localRuntimeStatus: String {
        let models = DesktopLocalTranscription.models(host: .windows)
        let installer = localInstaller
        let downloaded = models.filter { installer.state(of: .init($0)) == .installed }.count
        let counts = "\(downloaded) of \(models.count) on-device models downloaded."
        if let failure = localModels.runtimeFailure { return failure + " " + counts }
        guard localRuntimeBundled else {
            return "The on-device speech runtime (whisper.cpp) is not included in this build. " + counts
        }
        if let runtime = localModels.runtime { return "On-device: \(runtime.description). " + counts }
        let gpu = localUseGPU ? "a Vulkan GPU when available, otherwise the CPU" : "the CPU"
        return "On-device with whisper.cpp 1.9.4 using \(gpu). Audio stays on this PC. " + counts
    }

    func publishLocalModels() {
        guard !closed, let context = localModels.context else { return }
        let installer = localInstaller
        var labels: [String: String] = [:]
        var rows: [WindowsLocalModelRow] = []
        for spec in DesktopLocalTranscription.models(host: .windows) {
            let (row, label) = localModelRow(spec, installer: installer)
            rows.append(row)
            labels[spec.catalogueID] = label
        }
        WindowsModels.setLocalLabels(labels)
        publishModelCatalog(modelCatalog.snapshot)
        let status = localRuntimeStatus
        let useGPU: Int32 = localUseGPU ? 1 : 0
        withCStrings(rows.flatMap { [$0.name, $0.detail, $0.about] } + [status]) { pointers in
            let native = rows.indices.map { index in
                JSTILocalModelRow(
                    name: pointers[index * 3], detail: pointers[index * 3 + 1], about: pointers[index * 3 + 2],
                    state: rows[index].state
                )
            }
            _ = native.withUnsafeBufferPointer {
                jsti_window_set_local_models(
                    $0.baseAddress, $0.count, pointers[rows.count * 3], useGPU, localModelEvent, context
                )
            }
        }
    }

    /// One model's row in the Local models dialog, and the state shown after
    /// its name in the model picker unless it is simply downloaded.
    private func localModelRow(
        _ spec: WindowsModelSpec, installer: LocalModelInstaller
    ) -> (row: WindowsLocalModelRow, label: String?) {
        let size = Self.megabytes(spec.artifact.byteCount)
        let state: Int32
        let detail: String
        var label: String?
        if let received = localModels.progress[spec.catalogueID], localModels.downloads[spec.catalogueID] != nil {
            state = Int32(JSTI_LOCAL_MODEL_DOWNLOADING.rawValue)
            detail = "Downloading \(received * 100 / max(spec.artifact.byteCount, 1))% of \(size)"
            label = "downloading"
        } else if localModels.ownership.isRemoving(spec.catalogueID) {
            // Only Remove stays enabled, and it is ignored until this removal finishes.
            state = Int32(JSTI_LOCAL_MODEL_INSTALLED.rawValue)
            detail = "\(size) \u{00B7} Removing\u{2026}"
            label = "removing"
        } else {
            switch installer.state(of: .init(spec)) {
            case .installed:
                state = Int32(JSTI_LOCAL_MODEL_INSTALLED.rawValue)
                detail = "\(size) \u{00B7} Downloaded and verified"
            case .partial(let received, let total):
                state = Int32(JSTI_LOCAL_MODEL_PARTIAL.rawValue)
                detail = "\(size) \u{00B7} \(received * 100 / max(total, 1))% downloaded, paused"
                label = "download paused"
            case .notInstalled:
                state = Int32(JSTI_LOCAL_MODEL_NOT_INSTALLED.rawValue)
                detail = "\(size) \u{00B7} Not downloaded"
                label = "download in Local models"
            }
        }
        let about = "\(spec.summary) Whisper weights (\(spec.quantization), \(spec.artifact.license) licence) "
            + "from huggingface.co/\(WhisperCppModels.repository), pinned by SHA-256 "
            + "\(spec.artifact.sha256.prefix(12))\u{2026} and verified after download."
        return (WindowsLocalModelRow(name: spec.displayName, detail: detail, about: about, state: state), label)
    }

    static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_048_576).rounded())) MB"
    }
}

typealias WindowsModelSpec = WhisperCppModel

extension SpeakWindowsMain {
    /// Source and Mode pickers, then the Local models dialog.
    static func configureModelPickers(_ controller: WindowsAppController, holder: WindowsEventContext) async throws {
        let preferences = await controller.preferredModelIDs()
        try WindowsModels.configureModes(batch: preferences.batch, live: preferences.live, local: preferences.local)
        await controller.configureLocalModels(context: Unmanaged.passUnretained(holder).toOpaque())
    }
}

struct WindowsLocalModelRow {
    let name: String
    let detail: String
    let about: String
    let state: Int32
}

/// Borrowed NUL-terminated copies of `strings`, valid only inside `body`.
func withCStrings<Result>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) -> Result) -> Result {
    let owned = strings.map { string -> UnsafeMutablePointer<CChar> in
        let chars = Array(string.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
        pointer.initialize(from: chars, count: chars.count)
        return pointer
    }
    defer { owned.forEach { $0.deallocate() } }
    return body(owned.map { UnsafePointer($0) })
}

/// An action from the native Local models dialog, on the UI thread.
func localModelEvent(_ action: Int32, _ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    holder.enqueueSettings { await holder.controller.localModelAction(action, index: Int(index)) }
}
