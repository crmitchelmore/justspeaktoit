#if os(iOS)
import Foundation
import SpeakCore

/// Download, prepare and remove state for one downloaded model.
public enum IOSLocalModelInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)
}

/// Settings' view of the downloaded transcription models: the iOS catalogue
/// projection plus imports, each with its install state.
@MainActor
public final class IOSLocalModelManager: ObservableObject {
    public static let shared = IOSLocalModelManager()

    @Published public private(set) var importedModels: [LocalTranscriptionModel]
    @Published public private(set) var states: [String: IOSLocalModelInstallState] = [:]

    private let store: IOSImportedLocalModelStore
    private let engineProvider: () -> IOSLocalTranscriptionEngine?
    private let freeSpaceBytes: () -> Int64?
    private var downloads: [String: Task<Void, Never>] = [:]

    public init(
        store: IOSImportedLocalModelStore = .shared,
        engine: @escaping () -> IOSLocalTranscriptionEngine? = { IOSLocalTranscriptionEngines.current },
        freeSpaceBytes: @escaping () -> Int64? = IOSLocalModelManager.availableCapacity
    ) {
        self.store = store
        engineProvider = engine
        self.freeSpaceBytes = freeSpaceBytes
        importedModels = store.load()
        refresh()
    }

    public var engineAvailable: Bool { engineProvider() != nil }

    public var catalogueModels: [LocalTranscriptionModel] { ModelCatalog.iOSLocalTranscription }

    public var models: [LocalTranscriptionModel] {
        IOSLocalTranscriptionModels.all(imported: importedModels)
    }

    public func state(for model: LocalTranscriptionModel) -> IOSLocalModelInstallState {
        states[model.id] ?? .notInstalled
    }

    public func installedSizeBytes(_ model: LocalTranscriptionModel) -> Int64? {
        engineProvider()?.installedSizeBytes(model)
    }

    public func isRecommended(_ model: LocalTranscriptionModel) -> Bool {
        engineProvider()?.isRecommendedOnThisDevice(model) ?? true
    }

    /// Re-reads install state from disk, keeping any download in progress.
    public func refresh() {
        let engine = engineProvider()
        for model in models where downloads[model.id] == nil {
            states[model.id] = engine?.isInstalled(model) == true ? .installed : .notInstalled
        }
    }

    public func download(_ model: LocalTranscriptionModel) {
        guard downloads[model.id] == nil else { return }
        guard let engine = engineProvider() else {
            states[model.id] = .failed(IOSLocalTranscriptionError.engineUnavailable.localizedDescription)
            return
        }
        let neededBytes = Int64(max(model.approximateSizeMB, 1)) * 1_048_576
        if let free = freeSpaceBytes(), free < neededBytes * 2 {
            states[model.id] = .failed(
                IOSLocalTranscriptionError.insufficientSpace(neededMB: model.approximateSizeMB * 2).localizedDescription
            )
            return
        }
        states[model.id] = .downloading(0)
        let modelID = model.id
        downloads[modelID] = Task { [weak self] in
            do {
                try await engine.install(model) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.states[modelID] else { return }
                        self.states[modelID] = .downloading(min(max(fraction, 0), 1))
                    }
                }
                self?.finishDownload(modelID, state: .installed)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    try? engine.remove(model)
                    self?.finishDownload(modelID, state: .notInstalled)
                } else {
                    self?.finishDownload(modelID, state: .failed(error.localizedDescription))
                }
            }
        }
    }

    public func cancelDownload(_ model: LocalTranscriptionModel) {
        downloads[model.id]?.cancel()
    }

    private func finishDownload(_ modelID: String, state: IOSLocalModelInstallState) {
        downloads[modelID] = nil
        states[modelID] = state
    }

    /// Deletes a model's files. A model transcribing a recording is kept.
    public func remove(_ model: LocalTranscriptionModel) throws {
        guard downloads[model.id] == nil else { throw IOSLocalTranscriptionError.modelInUse(model.displayName) }
        guard !IOSLocalTranscriptionModels.isInUse(model.id) else {
            throw IOSLocalTranscriptionError.modelInUse(model.displayName)
        }
        guard let engine = engineProvider() else { throw IOSLocalTranscriptionError.engineUnavailable }
        try engine.remove(model)
        states[model.id] = .notInstalled
    }

    /// Adds a WhisperKit model from a Hugging Face repository.
    @discardableResult
    public func importModel(repoID: String, modelName: String) throws -> LocalTranscriptionModel {
        let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HuggingFaceRepoInput.isValidRepoID(repoID) else {
            throw IOSLocalTranscriptionError.invalidRepository(repoID)
        }
        guard !modelName.isEmpty else { throw IOSLocalTranscriptionError.missingModelName }
        let model = WhisperKitHuggingFaceModels.importedModel(repoID: repoID, modelName: modelName)
        let updated = WhisperKitHuggingFaceModels.deduplicated(importedModels + [model])
        try store.save(updated)
        importedModels = updated
        refresh()
        return model
    }

    /// Removes an imported model's files and forgets the import.
    public func removeImport(_ model: LocalTranscriptionModel) throws {
        if engineProvider()?.isInstalled(model) == true { try remove(model) }
        let updated = importedModels.filter { $0.id != model.id }
        try store.save(updated)
        importedModels = updated
        states[model.id] = nil
    }

    public func isImported(_ model: LocalTranscriptionModel) -> Bool {
        importedModels.contains { $0.id == model.id }
    }

    public nonisolated static func availableCapacity() -> Int64? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
#endif
