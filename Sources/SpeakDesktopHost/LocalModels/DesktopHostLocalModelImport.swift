import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopHostLocalModelPlatform {
    /// Starts owned work and returns immediately to the native settings queue.
    /// Import saves a pinned reference; downloading weights is a separate click.
    package func importLocalModel(repository: String, filename: String) {
        guard !closed else { return }
        guard localModels.importTask == nil else {
            localImportNotice("An import is already running. Cancel it before importing another model.")
            return
        }
        do {
            try HuggingFaceWhisperModel.validateInput(repository: repository, filename: filename)
            guard Platform.localModelHost.canExecute(.whisperCppGGML) else {
                throw DesktopTranscriptionError.unsupportedModel
            }
        } catch {
            localImportNotice(error.localizedDescription)
            return
        }
        let discovery = HuggingFaceWhisperDiscovery(transport: Platform.localModelMetadataTransport)
        activeOperations += 1
        localModels.importTask = Task { [self] in
            defer {
                localModels.importTask = nil
                finishOperation()
            }
            do {
                let model = try await discovery.discover(repository: repository, filename: filename)
                try Task.checkCancellation()
                guard !closed else { return }
                try await saveLocalImport(model)
            } catch is CancellationError {
                localImportNotice("Model import cancelled. No weights were downloaded.")
            } catch {
                localImportNotice("Model import failed: \(error.localizedDescription)")
            }
        }
        localImportNotice("Inspecting \(repository)/\(filename). No weights are downloaded until you choose Download.")
    }

    package func cancelLocalModelImport() {
        guard !closed else { return }
        localModels.importTask?.cancel()
    }

    private func saveLocalImport(_ model: HuggingFaceWhisperModel) async throws {
        if let existing = localModels.imported.first(where: { $0.id == model.id }) {
            localImportNotice("\(existing.displayName) is already imported. Choose Download to install it.")
            return
        }
        let proposed = localModels.imported + [model]
        let option = DesktopLocalTranscription.option(model.model)
        var projected = DesktopHostModels.snapshot
        try projected.appendLocal([option])
        let store = HuggingFaceWhisperStore(
            directory: directory.appendingPathComponent(Self.localModelsFolder),
            prepareDirectory: { try Platform.preparePrivateDirectory($0) }
        )
        let worker = Task.detached { try store.save(proposed) }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        // Saving is the commit point. Cancellation after it cannot truthfully
        // claim the reference was not saved; it still never installs weights.
        guard !closed else { return }
        do {
            try DesktopHostModels.appendLocal([option])
        } catch {
            localImportNotice(
                "The model reference was saved, but this window's model slots filled during the import. "
                    + "Restart the app to load it. No weights were downloaded."
            )
            return
        }
        localModels.imported = proposed
        DesktopLocalTranscription.rememberImportedNames([model])
        localImportNotice(
            "\(model.displayName) imported at \(model.revision), \(model.byteCount) bytes, "
                + "SHA-256 \(model.sha256). Choose Download, then Source: Local / Batch."
        )
        publishModelCatalog(modelCatalog.snapshot)
    }

    private func localImportNotice(_ message: String) {
        localModels.importStatus = message
        update(message)
        publishLocalModels()
    }
}
