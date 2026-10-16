import Foundation
import SpeakCore
import SpeakDesktop

package enum DesktopHostLocalCleanup {
    package static var runtimeDirectory: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("LocalLLMRuntime", isDirectory: true)
    }

    package static func makeStore(
        directory: URL, digests: LocalModelDigestProvider,
        prepareDirectory: @escaping @Sendable (URL) throws -> Void
    ) throws -> DesktopLocalLLMStore {
        guard let runtimeDirectory else {
            throw LocalLLMError.runtimeUnavailable("The app's executable directory could not be resolved.")
        }
        return try .init(
            directory: directory, digests: digests,
            runtime: NativeLocalLLMRuntime(directory: runtimeDirectory, digests: digests),
            prepareDirectory: prepareDirectory
        )
    }
}

extension DesktopHostController {
    /// Called once the native window/context exists. Subsequent refreshes keep
    /// the same presenter and never ask a settings queue to await model work.
    package func configureLocalCleanup(presenter: UnsafeMutableRawPointer? = nil) async {
        localCleanupPresenter = presenter
        localCleanupPresenting = true
        await publishLocalCleanup()
    }

    package func localCleanupAction(
        _ action: Int32, identifier: String, repository: String = "", filename: String = ""
    ) {
        guard !closed else { return }
        if action == 3 {
            localCleanupTask?.cancel()
            return
        }
        guard let localCleanup else {
            update("This host has no native downloaded-model cleanup adapter.")
            return
        }
        guard localCleanupTask == nil else {
            update("A local cleanup model operation is running. Cancel it or wait for it to finish.")
            return
        }
        guard [1, 2, 4].contains(action) else {
            update("Unknown local cleanup model action.")
            return
        }
        activeOperations += 1
        let operationID = UUID()
        localCleanupOperationID = operationID
        localCleanupPercent = -1
        localCleanupTask = Task { [self] in
            defer { localCleanupTask = nil; localCleanupOperationID = nil; finishOperation() }
            do {
                switch action {
                case 1:
                    // Recommended references use exactly the same metadata
                    // flow as imports; no invented payload hashes are shipped.
                    let rows = await localCleanup.rows()
                    guard let row = rows.first(where: { $0.model.id == identifier }) else {
                        throw LocalLLMError.metadataRequired
                    }
                    if row.metadata == nil {
                        _ = try await localCleanup.resolve(repository: row.model.repoID, filename: row.model.filename)
                    }
                    try await localCleanup.install(identifier) { [self] received, total in
                        Task { await self.localCleanupProgress(id: operationID, received: received, total: total) }
                    }
                    localCleanupNotice = "Model downloaded and verified. Select Local, Batch in post-processing."
                case 2:
                    try await localCleanup.remove(identifier)
                    localCleanupNotice = "Downloaded weights removed. Model reference and History names are retained."
                default:
                    let imported = try await localCleanup.resolve(repository: repository, filename: filename)
                    localCleanupNotice = "\(imported.model.displayName) reference pinned. Download installs the weights."
                }
            } catch is CancellationError {
                localCleanupNotice = "Operation cancelled. Partial download bytes are kept for Resume."
            } catch { localCleanupNotice = error.localizedDescription }
            await publishLocalCleanup()
            if !closed { update(localCleanupNotice) }
        }
    }

    private func localCleanupProgress(id: UUID, received: Int64, total: Int64) async {
        guard !closed, localCleanupTask != nil, localCleanupOperationID == id else { return }
        let percent = Int(received * 100 / max(total, 1))
        guard percent > localCleanupPercent else { return }
        localCleanupPercent = percent
        localCleanupNotice = "Downloading local cleanup model: \(percent)%."
        await publishLocalCleanup()
    }

    package func publishLocalCleanup() async {
        guard !closed, localCleanupPresenting, let localCleanup else { return }
        let rows = await localCleanup.rows()
        guard !closed else { return }
        let runtime: String
        if let directory = DesktopHostLocalCleanup.runtimeDirectory {
            do {
                _ = try NativeLocalLLMProvisioning.read(directory: directory)
                runtime = "Pinned native CPU runtime provisioned; library digest and model compatibility are checked on use. "
                    + "Provisioning alone does not establish model compatibility."
            } catch { runtime = error.localizedDescription }
        } else { runtime = "The app's native-runtime directory could not be resolved." }
        Platform.presentLocalCleanup(
            rows, status: runtime + (localCleanupNotice.isEmpty ? "" : " " + localCleanupNotice),
            presenter: localCleanupPresenter
        )
        let choices = DesktopLocalLLMModels.choices(selected: settings.postProcessing?.modelIdentifier).map(\.id)
        if choices != localCleanupChoices {
            localCleanupChoices = choices
            Platform.presentPostProcessing(postProcessingOptions(), presenter: localCleanupPresenter)
        }
    }
}
