import Foundation
import SpeakCore
import SpeakDesktop

/// What on-device readiness, recognition and live clients may use of the
/// host: the local-model state, the folder models live in, the GPU choice, the
/// status line and the model picker. The `DesktopHostPlatform` local-runtime
/// hooks receive only this, so they cannot reach recordings, credentials,
/// output or the rest of the settings. `DesktopHostController` is the conformer.
package protocol DesktopHostLocalModelHost<Platform>: Actor {
    associatedtype Platform: DesktopHostPlatform

    /// The settings folder; downloaded models live in its `LocalModels` folder.
    nonisolated var directory: URL { get }
    var localModels: Platform.LocalModelsState { get set }
    /// Whether the runtime may use the GPU when it next loads.
    var localUseGPU: Bool { get }
    /// True once the host has shut down; nothing is presented after that.
    var closed: Bool { get }
    func update(_ status: String, transcript: String?, state: Int32)
    /// Lists the models again after an on-device model's state label changed.
    func refreshModelPicker()
}

extension DesktopHostController: DesktopHostLocalModelHost {
    package var localUseGPU: Bool { settings.localUseGPU ?? true }

    package func refreshModelPicker() { publishModelCatalog(modelCatalog.snapshot) }
}

// Readiness and recognition of downloaded models, shared by every host with a
// local runtime and written against the narrow host above.
extension DesktopHostLocalModelHost where Platform: DesktopHostLocalModelPlatform {
    package static var localModelsFolder: String { "LocalModels" }

    /// The on-device models this host offers, in catalogue order.
    package var localModelSpecs: [WhisperCppModel] { localModels.specs(host: Platform.localModelHost) }

    /// The model behind a batch identifier or, for live use, the batch model
    /// a `local/streaming/whisperkit/...` identifier streams with.
    package func localModelSpec(for identifier: String) -> WhisperCppModel? {
        localModels.spec(for: identifier, host: Platform.localModelHost)
    }

    package var localInstaller: LocalModelInstaller {
        let root = directory.appendingPathComponent(Self.localModelsFolder, isDirectory: true)
        return LocalModelInstaller(
            root: root, digests: Platform.localModelDigests, transport: Platform.localModelTransport,
            validateArtifact: { item, file in
                if item.identifier.hasPrefix(HuggingFaceWhisperModel.identifierPrefix) {
                    try WhisperGGMLImportValidation.validate(file, filename: item.artifact.filename)
                }
            },
            prepareDirectory: { url in
                // Both levels are private to the user; a model folder's parent must exist first.
                for folder in [root, url] { try Platform.preparePrivateDirectory(folder) }
            }
        )
    }

    /// Why an on-device model cannot run now, or nil when it can. A runtime
    /// that failed to start is not a reason: the next use opens it again, so a
    /// library that was being installed or repaired needs no restart.
    package func localReadiness(_ model: String) -> String? {
        guard let spec = localModelSpec(for: model) else {
            return "This on-device model is not available in this \(Platform.displayName) build."
        }
        if localModels.ownership.isRemoving(spec.catalogueID) {
            return "\(spec.displayName) is being removed from \(Platform.localDeviceName)."
        }
        if let missing = Platform.localRuntimeMissing { return missing }
        guard localInstaller.state(of: .init(spec)) == .installed else {
            return "\(spec.displayName) is not downloaded yet. Open Local models to download it."
        }
        return nil
    }

    /// Loads the runtime off the actor and keeps it once it opens. A failed
    /// open is shown in Local models and tried again on the next use.
    package func localRuntime() async throws -> Platform.LocalRuntime {
        if let runtime = localModels.runtime { return runtime }
        let allowGPU = localUseGPU
        do {
            let runtime = try await Task.detached { try Platform.openLocalRuntime(allowGPU: allowGPU) }.value
            localModels.runtime = runtime
            localModels.runtimeFailure = nil
            publishLocalModels()
            return runtime
        } catch {
            let failure = "The on-device speech runtime could not start: \(error.localizedDescription)"
            localModels.runtimeFailure = failure
            publishLocalModels()
            throw DesktopHostError(message: failure)
        }
    }

    package func transcribeLocally(_ audio: URL, model: String, language: String?) async throws -> TranscriptionResult {
        guard let spec = localModelSpec(for: model) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        if let problem = localReadiness(model) { throw DesktopHostError(message: problem) }
        // Checked and held together: no removal can start before recognition ends.
        let used = Platform.beginLocalUse(model, in: &localModels)
        defer { if let used { Platform.endLocalUse(used, in: &localModels) } }
        let file = try localInstaller.verifiedFile(for: .init(spec))
        let runtime = try await localRuntime()
        update(
            "Transcribing on \(Platform.localDeviceName) with \(spec.displayName)\u{2026} "
                + "Your recording is saved locally.",
            transcript: nil, state: 2
        )
        // The runtime hashes the bytes it loads and uses them only when they
        // match the pinned SHA-256, so the file is not hashed separately here.
        do {
            return try await DesktopLocalTranscription.transcribe(
                audioURL: audio, model: spec, modelFile: file, language: language, recognizer: runtime.recognizer
            )
        } catch DesktopLocalTranscriptionError.modelDoesNotMatchDigest {
            throw discardMismatchedModel(spec)
        }
    }

    /// Streams a pinned downloaded model in process. The recording holds the
    /// model through `beginLocalUse`, so it cannot be removed meanwhile.
    package func makeLocalLiveClient(
        _ model: String, language: String?
    ) async throws -> (any FinalizingStreamingTranscriptionClient)? {
        guard DesktopHostModels.isLocalLive(model),
              let spec = DesktopLocalStreaming.model(forLiveID: model, host: Platform.localModelHost),
              localModelSpec(for: model)?.catalogueID == spec.catalogueID else { return nil }
        if let problem = localReadiness(model) { throw DesktopHostError(message: problem) }
        let file = try localInstaller.verifiedFile(for: .init(spec))
        let runtime = try await localRuntime()
        return DesktopLocalStreamingClient(
            recognizer: runtime.recognizer, model: spec, modelFile: file, language: language
        )
    }
}
