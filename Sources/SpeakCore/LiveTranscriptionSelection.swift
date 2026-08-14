import Foundation

/// Where a live transcription model runs. Derived from the model identifier so
/// the catalogue stays the single source of truth for placement.
public enum LiveTranscriptionPlacement: String, CaseIterable, Sendable {
    case onDevice
    case remote

    public init(modelID: String) {
        self = ModelCatalog.isOnDeviceLiveTranscriptionModel(modelID) ? .onDevice : .remote
    }
}

/// Remembers the user's live-transcription model choice for each placement so
/// moving between local and remote never discards the other placement's model.
///
/// The app stores one *active* live model, which made the two placements share
/// a single slot: selecting Apple Speech overwrote a remote choice such as
/// Soniox, and returning to remote fell back to the catalogue default
/// (Deepgram). Keeping a remembered value per placement means a default is only
/// ever applied when there is no prior valid choice.
public struct LiveTranscriptionSelection: Equatable, Sendable {
    public private(set) var onDeviceModel: String?
    public private(set) var remoteModel: String?

    public init(onDeviceModel: String? = nil, remoteModel: String? = nil) {
        self.onDeviceModel = Self.sanitised(onDeviceModel, for: .onDevice)
        self.remoteModel = Self.sanitised(remoteModel, for: .remote)
    }

    public func rememberedModel(for placement: LiveTranscriptionPlacement) -> String? {
        switch placement {
        case .onDevice: return onDeviceModel
        case .remote: return remoteModel
        }
    }

    /// Records a user selection against the placement the model belongs to.
    /// Empty, misplaced, or non-live identifiers are ignored so a transient
    /// value can never evict a good one. Custom remote identifiers remain valid
    /// because macOS deliberately supports them.
    public mutating func remember(_ modelID: String) {
        switch LiveTranscriptionPlacement(modelID: modelID) {
        case .onDevice:
            if let sanitised = Self.sanitised(modelID, for: .onDevice) { onDeviceModel = sanitised }
        case .remote:
            if let sanitised = Self.sanitised(modelID, for: .remote) { remoteModel = sanitised }
        }
    }

    /// Fills an empty slot without overwriting an existing memory. Used when
    /// upgrading from a build that only stored the active model.
    public mutating func rememberIfMissing(_ modelID: String) {
        let placement = LiveTranscriptionPlacement(modelID: modelID)
        guard rememberedModel(for: placement) == nil else { return }
        remember(modelID)
    }

    /// The model that should become active when `placement` is selected.
    ///
    /// Resolution order: keep the active model when it already matches the
    /// placement, then the remembered choice, then the catalogue default, then
    /// any selectable model for that placement. `selectableModelIDs` restricts
    /// the result to identifiers the current platform can actually run; `nil`
    /// means unrestricted.
    public func model(
        for placement: LiveTranscriptionPlacement,
        activeModel: String,
        selectableModelIDs: Set<String>? = nil
    ) -> String {
        let candidates = [activeModel, rememberedModel(for: placement)].compactMap { $0 }
        for candidate in candidates
        where LiveTranscriptionPlacement(modelID: candidate) == placement
            && Self.isKnown(candidate)
            && Self.isSelectable(candidate, in: selectableModelIDs) {
            return candidate
        }

        if let fallback = Self.defaultModel(for: placement),
           Self.isSelectable(fallback, in: selectableModelIDs) {
            return fallback
        }

        let firstSelectable = Self.catalogue(for: placement)
            .map(\.id)
            .first { Self.isSelectable($0, in: selectableModelIDs) }
        return firstSelectable ?? activeModel
    }

    // MARK: - Catalogue helpers

    private static func catalogue(for placement: LiveTranscriptionPlacement) -> [ModelCatalog.Option] {
        switch placement {
        case .onDevice: return ModelCatalog.onDeviceLiveTranscription
        case .remote: return ModelCatalog.remoteLiveTranscription
        }
    }

    private static func defaultModel(for placement: LiveTranscriptionPlacement) -> String? {
        switch placement {
        case .onDevice: return ModelCatalog.defaultOnDeviceLiveTranscriptionModel
        case .remote: return ModelCatalog.defaultRemoteLiveTranscriptionModel
        }
    }

    /// Apple identifiers are accepted beyond the catalogue because the
    /// available on-device engines vary by OS version. Remote identifiers may
    /// also be custom, but known batch, post-processing, and local model IDs do
    /// not belong in the live-selection slot.
    private static func isKnown(_ modelID: String) -> Bool {
        if LiveTranscriptionPlacement(modelID: modelID) == .onDevice { return true }
        switch ModelRouting.family(for: modelID) {
        case .cloudStreaming:
            return true
        case .unknown(let provider):
            return provider != nil && modelID != ModelCatalog.customOptionID && modelID.contains("/")
        case .appleSpeech, .downloadedLocal, .cloudBatch, .postProcessing:
            return false
        }
    }

    private static func isSelectable(_ modelID: String, in selectableModelIDs: Set<String>?) -> Bool {
        guard let selectableModelIDs else { return true }
        return selectableModelIDs.contains(modelID)
    }

    private static func sanitised(
        _ modelID: String?,
        for placement: LiveTranscriptionPlacement
    ) -> String? {
        guard let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalised = ModelCatalog.normalizedLiveTranscriptionModel(modelID)
        guard LiveTranscriptionPlacement(modelID: normalised) == placement, isKnown(normalised) else {
            return nil
        }
        return normalised
    }
}

// MARK: - Persistence

public extension LiveTranscriptionSelection {
    /// Canonical defaults keys. Both platforms use these so a settings value has
    /// exactly one storage path.
    enum DefaultsKey {
        public static let onDeviceModel = "rememberedOnDeviceLiveTranscriptionModel"
        public static let remoteModel = "rememberedRemoteLiveTranscriptionModel"
    }

    init(defaults: UserDefaults) {
        self.init(
            onDeviceModel: defaults.string(forKey: DefaultsKey.onDeviceModel),
            remoteModel: defaults.string(forKey: DefaultsKey.remoteModel)
        )
    }

    func persist(to defaults: UserDefaults) {
        Self.write(onDeviceModel, forKey: DefaultsKey.onDeviceModel, to: defaults)
        Self.write(remoteModel, forKey: DefaultsKey.remoteModel, to: defaults)
    }

    private static func write(_ value: String?, forKey key: String, to defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
