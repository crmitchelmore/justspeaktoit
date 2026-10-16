import Foundation
import SpeakCore

/// The single device-local model manager for both native hosts. This does not
/// own a second settings store: the host retains Options and selected identity.
public actor DesktopLocalLLMStore: DesktopLocalLLMEngine {
    public struct Row: Sendable {
        public let model: LocalPostProcessingModel
        public let metadata: HuggingFaceGGUFModel?
        public let state: LocalModelInstallState
        public let inUse: Bool
        public let downloading: Bool
        public let removing: Bool
    }
    private let store: HuggingFaceGGUFStore
    private let installer: LocalModelInstaller
    private let discovery: HuggingFaceGGUFDiscovery
    private let runtime: any DesktopLocalLLMRuntime
    private var models: [HuggingFaceGGUFModel]
    private var ownership = LocalModelOwnership()
    private var runs: [UUID: Task<String, Error>] = [:]
    private var closed = false

    public init(
        directory: URL, digests: LocalModelDigestProvider,
        transport: any LocalModelDownloadTransport = LocalModelURLSessionTransport(),
        metadataTransport: any HuggingFaceModelMetadataTransport = HuggingFaceModelMetadataHTTP(),
        runtime: any DesktopLocalLLMRuntime, prepareDirectory: @escaping @Sendable (URL) throws -> Void
    ) throws {
        store = HuggingFaceGGUFStore(directory: directory, prepareDirectory: prepareDirectory)
        models = try store.load()
        DesktopLocalLLMModels.remember(models)
        discovery = HuggingFaceGGUFDiscovery(transport: metadataTransport)
        self.runtime = runtime
        let root = directory.appendingPathComponent("LocalCleanupModels", isDirectory: true)
        installer = LocalModelInstaller(
            root: root, digests: digests, transport: transport,
            validateArtifact: { _, file in try GGUFImportValidation.validate(file) },
            prepareDirectory: { url in
                try prepareDirectory(root)
                try prepareDirectory(url)
            }
        )
    }

    public func rows() -> [Row] {
        let recommended = ModelCatalog.localPostProcessing
        let all = recommended + models.filter { value in !recommended.contains { $0.id == value.id } }.map(\.model)
        return all.map { model in
            let metadata = models.first { $0.id == model.id }
            let owner = metadata?.storageIdentifier ?? model.id
            return Row(
                model: model, metadata: metadata,
                state: metadata.map { installer.state(of: item($0)) } ?? .notInstalled,
                inUse: ownership.isInUse(owner), downloading: ownership.isDownloading(owner),
                removing: ownership.isRemoving(owner)
            )
        }
    }

    /// Explicit network metadata approval/import. A changed revision cannot
    /// silently replace already pinned metadata or downloaded selection.
    @discardableResult
    public func resolve(repository: String, filename: String) async throws -> HuggingFaceGGUFModel {
        guard !closed else { throw LocalLLMError.closed }
        let model = try await discovery.discover(repository: repository, filename: filename)
        try Task.checkCancellation()
        guard !closed else { throw LocalLLMError.closed }
        if let previous = models.first(where: { $0.id == model.id }) {
            guard previous == model else {
                throw LocalLLMError.inference("This reference is already pinned to another revision. Remove its reference first.")
            }
            return previous
        }
        let changed = models + [model]
        try store.save(changed)
        models = changed
        DesktopLocalLLMModels.remember(models)
        DesktopLocalLLMModels.remember(models)
        return model
    }

    public func install(_ identifier: String, progress: @escaping LocalModelInstaller.Progress = { _, _ in }) async throws {
        guard !closed else { throw LocalLLMError.closed }
        let model = try spec(identifier)
        let owner = model.storageIdentifier
        guard !ownership.isInUse(owner), ownership.beginDownload(owner) else { throw LocalLLMError.busy }
        defer { ownership.endDownload(owner) }
        _ = try await installer.install(item(model), progress: progress)
    }

    /// No model remains cached by the runtime after a run; its file lease is
    /// released before complete returns. Removal never races active inference.
    public func remove(_ identifier: String, forget: Bool = false) async throws {
        guard !closed else { throw LocalLLMError.closed }
        let model = try spec(identifier)
        guard ownership.beginRemoval(model.storageIdentifier) else { throw LocalLLMError.busy }
        defer { ownership.endRemoval(model.storageIdentifier) }
        let installer = installer
        let item = item(model)
        try await Task.detached { try installer.remove(item) }.value
        if forget {
            let changed = models.filter { $0.id != identifier }
            try store.save(changed)
            models = changed
        }
    }

    public func complete(
        modelIdentifier: String, systemPrompt: String, userPrompt: String, temperature: Double
    ) async throws -> String {
        try Task.checkCancellation()
        guard !closed else { throw LocalLLMError.closed }
        let model = try spec(modelIdentifier)
        let owner = model.storageIdentifier
        guard !ownership.isRemoving(owner), !ownership.isDownloading(owner) else { throw LocalLLMError.busy }
        let file = try installer.verifiedFile(for: item(model))
        ownership.beginUse(owner)
        let id = UUID()
        let runtime = runtime
        let task = Task {
            try await runtime.complete(
                model: model, file: file, systemPrompt: systemPrompt, userPrompt: userPrompt, temperature: temperature
            )
        }
        runs[id] = task
        defer { runs[id] = nil; ownership.endUse(owner) }
        do {
            return try await withTaskCancellationHandler {
                let text = try await task.value
                try Task.checkCancellation()
                guard !closed else { throw LocalLLMError.closed }
                return text
            } onCancel: { task.cancel() }
        } catch LocalModelInstallError.checksumMismatch {
            installer.discardMismatched(item(model))
            throw LocalModelInstallError.checksumMismatch
        }
    }

    public func close() {
        closed = true
        for task in runs.values { task.cancel() }
        // Running workers retain runtime/model snapshots until native teardown.
    }

    private func spec(_ identifier: String) throws -> HuggingFaceGGUFModel {
        guard let model = models.first(where: { $0.id == identifier }) else { throw LocalLLMError.metadataRequired }
        return model
    }
    private func item(_ model: HuggingFaceGGUFModel) -> LocalModelInstaller.Item {
        let source = model.artifact
        return .init(
            identifier: model.storageIdentifier, displayName: model.model.displayName,
            artifact: .init(
                url: source.url, filename: "model.gguf", byteCount: source.byteCount, sha256: source.sha256,
                license: source.license, provenance: source.provenance
            )
        )
    }
}
