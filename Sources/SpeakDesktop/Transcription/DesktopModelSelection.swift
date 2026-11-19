import Foundation
import SpeakCore

/// The desktop host's persisted transcription choice: the active model plus the
/// last batch and live selections, which the host restores when the user
/// switches mode.
///
/// Loading applies the same retired-identifier migrations as the Apple
/// settings (`ModelCatalog.normalizedBatchTranscriptionModel` and
/// `normalizedLiveTranscriptionModel`) before checking what this host can run,
/// so a retired identifier moves to its canonical successor rather than being
/// discarded. Each remembered slot then holds only a model of its own mode that
/// the host implements, and a runnable active model is always its mode's slot.
public struct DesktopModelSelection: Equatable, Sendable {
    public var model: String
    public var batchModel: String?
    public var liveModel: String?

    public init(model: String, batchModel: String?, liveModel: String?) {
        self.model = model
        self.batchModel = batchModel
        self.liveModel = liveModel
    }

    /// - Parameters:
    ///   - isLive: whether the host exposes an identifier as a live route.
    ///   - isBatch: whether the host can run an identifier as a batch route,
    ///     including saved dynamic selections the host keeps routable.
    public static func migrated(
        model: String?, batchModel: String?, liveModel: String?,
        isLive: (String) -> Bool, isBatch: (String) -> Bool
    ) -> DesktopModelSelection {
        func batch(_ identifier: String?) -> String? {
            guard let identifier = present(identifier) else { return nil }
            let migrated = ModelCatalog.normalizedBatchTranscriptionModel(identifier)
            return isBatch(migrated) && !isLive(migrated) ? migrated : nil
        }
        func live(_ identifier: String?) -> String? {
            guard let identifier = present(identifier) else { return nil }
            let migrated = ModelCatalog.normalizedLiveTranscriptionModel(identifier)
            return isLive(migrated) ? migrated : nil
        }
        var batchSlot = batch(batchModel)
        var liveSlot = live(liveModel)
        let active: String
        if let current = live(model) {
            active = current
            liveSlot = current
        } else if let current = batch(model) {
            active = current
            batchSlot = current
        } else if let remembered = batchSlot ?? liveSlot {
            // The active identifier cannot run here; keep the user's own
            // remembered choice rather than switching to an unrelated provider.
            active = remembered
        } else {
            active = ModelCatalog.defaultBatchTranscriptionModel
            if isBatch(active), !isLive(active) { batchSlot = active }
        }
        return DesktopModelSelection(model: active, batchModel: batchSlot, liveModel: liveSlot)
    }

    private static func present(_ identifier: String?) -> String? {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
