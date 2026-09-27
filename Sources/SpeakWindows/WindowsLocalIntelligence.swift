import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

/// On-device live transcription, local post-processing with a downloaded
/// language model, and Hugging Face imports.
extension WindowsAppController {
    // MARK: - Hugging Face imports

    /// Resolves the typed file on Hugging Face, pins it and lists it in Local
    /// models. The kind follows the file: `.bin` is a whisper.cpp speech
    /// model, `.gguf` a language model. Nothing downloads until the user asks.
    func importLocalModel(repository: String, file: String) {
        guard !localModels.importing else {
            update("Another Hugging Face import is still being checked.")
            return
        }
        guard let kind = HuggingFaceModelResolver.kind(forPath: file) else {
            update("Add a whisper.cpp .bin speech model or a .gguf language model.")
            return
        }
        do {
            _ = try HuggingFaceModelResolver.validate(repoID: repository, path: file, kind: kind)
        } catch {
            update(error.localizedDescription)
            return
        }
        localModels.importing = true
        activeOperations += 1
        update("Checking \(file) on Hugging Face\u{2026}")
        let fetch = HuggingFaceModelResolver.urlSessionFetch()
        Task { [self] in
            defer { finishOperation() }
            do {
                let model = try await HuggingFaceModelResolver.resolve(
                    repoID: repository, path: file, kind: kind, fetch: fetch
                )
                try await finishImport(model)
            } catch {
                localModels.importing = false
                update("Could not add \(file): \(error.localizedDescription)")
            }
        }
    }

    private func finishImport(_ model: DesktopImportedLocalModel) async throws {
        localModels.importing = false
        guard !closed else { return }
        var imports = DesktopLocalModelImports.registered
        imports.add(model)
        try saveImports(imports)
        if let speech = model.whisperModel {
            WindowsModels.addLocal(WindowsModels.option(for: speech))
            publishModelCatalog(modelCatalog.snapshot)
        }
        publishLocalModels()
        configurePostProcessingControls()
        update("\(model.displayName) added (\(Self.megabytes(model.byteCount)), pinned to revision "
            + "\(model.revision.prefix(12))). Select it and choose Download.")
    }

    /// Persists and registers the imports, so History and pickers see them.
    func saveImports(_ imports: DesktopLocalModelImports) throws {
        let effects = self.effects
        try imports.save(to: directory) { data, url in try effects.writeSettings(data, to: url) }
        DesktopLocalModelImports.register(imports)
    }

    /// Forgets an import whose file is gone.
    func forgetImport(_ identifier: String) {
        var imports = DesktopLocalModelImports.registered
        guard imports.model(for: identifier) != nil else { return }
        imports.remove(identifier: identifier)
        do { try saveImports(imports) } catch {
            update("Could not update imported models: \(error.localizedDescription)")
            return
        }
        WindowsModels.hideLocal(identifier)
        publishModelCatalog(modelCatalog.snapshot)
        configurePostProcessingControls()
    }

    // MARK: - Local language models

    /// Why a local post-processing choice cannot run now, or nil when it can.
    func languageModelReadiness(_ identifier: String) -> String? {
        if identifier.lowercased() == DesktopLocalPostProcessing.builtInRulesID { return nil }
        guard let model = DesktopLocalPostProcessing.model(for: identifier, host: .windows) else {
            return "This local post-processing model is not available in this Windows build."
        }
        if localModels.ownership.isRemoving(model.identifier) { return "\(model.displayName) is being removed." }
        guard WindowsLlamaRuntime.isBundled() else {
            return "This build does not include the on-device language model runtime. "
                + "Use the Windows bundle or package."
        }
        if let failure = localModels.languageRuntimeFailure { return failure }
        let item = WindowsLocalModelEntry.language(model).item
        guard localInstaller.state(of: item) == .installed else {
            return "\(model.displayName) is not downloaded yet. Open Local models to download it."
        }
        return nil
    }

    /// Loads llama.cpp once, off the actor.
    func languageRuntime() async throws -> WindowsLlamaRuntime {
        if let runtime = localModels.languageRuntime { return runtime }
        let allowGPU = localUseGPU
        do {
            let runtime = try await Task.detached { try WindowsLlamaRuntime.open(allowGPU: allowGPU) }.value
            localModels.languageRuntime = runtime
            publishLocalModels()
            return runtime
        } catch {
            localModels.languageRuntimeFailure =
                "The on-device language model runtime could not start: \(error.localizedDescription)"
            publishLocalModels()
            throw error
        }
    }

    /// Local post-processing: built-in rules, or a downloaded language model
    /// holding its file until it finishes.
    func processLocally(_ text: String, options: DesktopPostProcessing.Options) async throws
        -> DesktopPostProcessing.Outcome {
        let identifier = options.modelIdentifier
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text)
            || identifier.lowercased() == DesktopLocalPostProcessing.builtInRulesID {
            return try await DesktopPostProcessing.processLocally(
                rawText: text, options: options, model: nil, modelFile: nil, languageModel: nil
            )
        }
        if let problem = languageModelReadiness(identifier) { throw WindowsNativeError(message: problem) }
        guard let model = DesktopLocalPostProcessing.model(for: identifier, host: .windows) else {
            throw DesktopPostProcessingError.unsupportedModel
        }
        localModels.ownership.beginUse(model.identifier)
        defer { localModels.ownership.endUse(model.identifier) }
        let file = try localInstaller.verifiedFile(for: WindowsLocalModelEntry.language(model).item)
        let runtime = try await languageRuntime()
        update("Polishing on this PC with \(model.displayName)\u{2026} The original is saved in History.", state: 2)
        return try await DesktopPostProcessing.processLocally(
            rawText: text, options: options, model: model, modelFile: file,
            languageModel: WindowsLlamaLanguageModel(runtime: runtime)
        )
    }

    // MARK: - Local live transcription

    /// A live session over the sliding-window streamer for a qualified model.
    func makeLocalLiveSession(model: String, id: UUID, language: String?) async throws -> DesktopLiveSession {
        guard let spec = DesktopLocalTranscription.liveModel(for: model, host: .windows) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        if let problem = localReadiness(model) { throw WindowsNativeError(message: problem) }
        let file = try localInstaller.verifiedFile(for: .init(spec))
        let runtime = try await localRuntime()
        let client = DesktopLocalLiveClient(
            model: spec, modelFile: file, language: language, recognizer: WindowsWhisperRecognizer(runtime: runtime)
        )
        return DesktopLiveSession(client: client, id: id)
    }
}
