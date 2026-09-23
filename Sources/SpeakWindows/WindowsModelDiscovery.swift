import Foundation
import SpeakCore
import SpeakDesktop

extension WindowsAppController {
    static func prepareModelCatalog(directory: URL, settings: inout Settings) throws -> OpenRouterAudioCatalogStore {
        // Remote batch, live and on-device choices keep separate slots, so
        // switching Source restores each one's last model.
        let isLocal = WindowsModels.isLocal
        let remoteBatch = settings.batchModel.flatMap { isLocal($0) ? nil : $0 }
        let selection = DesktopModelSelection.migrated(
            model: settings.model, batchModel: remoteBatch, liveModel: settings.liveModel,
            isLive: WindowsModels.isLive, isBatch: { DesktopTranscription.provider(for: $0) != nil || isLocal($0) }
        )
        settings.model = selection.model
        settings.liveModel = selection.liveModel
        if let chosen = selection.batchModel, isLocal(chosen) {
            settings.localModel = chosen
            settings.batchModel = DesktopModelSelection.migrated(
                model: remoteBatch, batchModel: remoteBatch, liveModel: nil, isLive: WindowsModels.isLive,
                isBatch: { DesktopTranscription.provider(for: $0) != nil }
            ).batchModel
        } else {
            settings.batchModel = selection.batchModel
            settings.localModel = settings.localModel.flatMap { isLocal($0) ? $0 : nil }
        }
        let credential = DesktopTranscription.batchModels.lazy.compactMap { WindowsModels.provider(for: $0.id) }
            .first { $0.id == OpenRouterService.providerID }?.apiKeyIdentifier
        let catalog = OpenRouterAudioCatalogStore(
            apiKeyProvider: { credential.flatMap { try? WindowsNative.apiKey(name: $0) } },
            cacheURL: directory.appendingPathComponent("OpenRouterAudioCatalog.json")
        )
        try WindowsModels.update(
            discovered: catalog.snapshot.models,
            retaining: [settings.model, settings.batchModel, settings.liveModel].compactMap { $0 }
        )
        return catalog
    }

    /// Initial labels come from disk only; startup never waits for discovery.
    func configureModelCatalog() throws {
        try WindowsModels.publish(status: modelCatalogStatus(modelCatalog.snapshot), refreshing: false)
    }

    func refreshModels(force: Bool) {
        guard !closed else { return }
        if !force, modelDiscoveryTask != nil { return }
        modelDiscoveryTask?.cancel()
        let catalog = modelCatalog
        modelDiscoveryTask = Task.detached { [weak self] in
            let snapshot = await catalog.refresh(force: force) { [weak self] state in
                await self?.publishModelCatalog(state)
            }
            // Fresh cached state also publishes, even if no refresh was needed.
            await self?.publishModelCatalog(snapshot)
        }
    }

    func publishModelCatalog(_ state: OpenRouterAudioCatalogState) {
        guard !closed, state.revision >= modelCatalogRevision else { return }
        do {
            try WindowsModels.update(
                discovered: state.models,
                retaining: [settings.model, settings.batchModel, settings.liveModel].compactMap { $0 }
            )
            try WindowsModels.publish(status: modelCatalogStatus(state), refreshing: state.isRefreshing)
            modelCatalogRevision = state.revision
        } catch {
            // Catalogue feedback has its own control; recording status and
            // transcript text must remain unchanged while discovery completes.
            try? WindowsModels.publish(status: error.localizedDescription, refreshing: false)
        }
    }

    private func modelCatalogStatus(_ state: OpenRouterAudioCatalogState) -> String {
        if state.isRefreshing { return "Refreshing OpenRouter models… Current selection retained." }
        if let error = state.errorMessage { return error + " Saved models retained." }
        let count = state.models(for: .transcription).count
        guard let date = state.lastUpdated else { return "OpenRouter discovery not loaded. Refresh to find models." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "OpenRouter: \(count) transcription models · Updated \(formatter.string(from: date))."
    }
}
