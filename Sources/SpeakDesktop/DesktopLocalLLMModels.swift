import Foundation
import SpeakCore

/// Presentation only. The manager's immutable metadata and receipt, not this
/// projection or a transferred Mac identity, authorise execution.
public enum DesktopLocalLLMModels {
    private final class Names: @unchecked Sendable {
        let lock = NSLock()
        var models: [LocalPostProcessingModel] = []
    }
    private static let names = Names()

    public static func remember(_ models: [HuggingFaceGGUFModel]) {
        names.lock.withLock { names.models = models.map(\.model) }
    }

    public static func displayName(for identifier: String) -> String? {
        if let model = ModelCatalog.localPostProcessing.first(where: { $0.id == identifier }) {
            return model.displayName
        }
        return names.lock.withLock { names.models.first { $0.id == identifier }?.displayName }
    }

    public static func choices(selected: String? = nil) -> [ModelCatalog.Option] {
        let recommended = ModelCatalog.localPostProcessing
        let imported = names.lock.withLock { names.models }
        var models = DesktopPostProcessing.remoteModels + (recommended + imported.filter { entry in
            !recommended.contains { $0.id == entry.id }
        }).map(\.option)
        if let selected, LocalPostProcessingModel.isDownloadedModelID(selected),
           !models.contains(where: { $0.id == selected }) {
            models.append(.init(
                id: selected, displayName: ModelCatalog.friendlyName(for: selected) + " (reference not imported)",
                description: "Import immutable metadata on this device before downloading or using this model.",
                tags: [.privacy]
            ))
        }
        return models
    }
}
