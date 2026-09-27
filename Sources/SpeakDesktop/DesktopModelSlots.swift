import Foundation
import SpeakCore

/// Stable native event identities, independent of picker ordering and discovery retirement.
/// Existing slots never change their model ID or mode for this instance's lifetime.
public struct DesktopModelSlots: Sendable {
    public struct Entry: Sendable {
        public internal(set) var option: ModelCatalog.Option
        public let isLive: Bool
        /// A downloaded model the host runs on-device; with `isLive`, an
        /// on-device live model.
        public let isLocal: Bool
        public internal(set) var isAvailable: Bool
    }
    public enum Failure: LocalizedError {
        case capacityExceeded
        public var errorDescription: String? {
            "The model catalogue exceeds this window's capacity. Restart the app before refreshing models again."
        }
    }

    public private(set) var entries: [Entry]
    public private(set) var visibleIndices: [Int]
    private var indices: [String: Int]
    private let initial: [ModelCatalog.Option]
    /// Removed imports: their slots stay, but no refresh shows them again.
    private var hiddenLocal: Set<String> = []
    private let maximumSlots: Int

    public init(
        live: [ModelCatalog.Option], local: [ModelCatalog.Option] = [], localLive: [ModelCatalog.Option] = [],
        maximumSlots: Int = 10_000
    ) {
        let batch = DesktopTranscription.batchModels
        let localLiveIDs = Set(localLive.map(\.id))
        let liveIDs = Set(live.map(\.id)).union(localLiveIDs)
        let localIDs = Set(local.map(\.id)).subtracting(liveIDs).union(localLiveIDs)
        var seen = Set<String>()
        initial = (batch + local + live + localLive).filter { seen.insert($0.id).inserted }
        entries = initial.map {
            Entry(option: $0, isLive: liveIDs.contains($0.id), isLocal: localIDs.contains($0.id), isAvailable: true)
        }
        indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.option.id, $0.offset) })
        visibleIndices = Array(entries.indices)
        self.maximumSlots = max(entries.count, maximumSlots)
    }

    /// The caller supplies a canonical visible projection. Retained valid dynamic
    /// selections stay visible even when absent from the latest catalogue.
    /// Capacity failures are atomic: no partially added identity slots escape.
    public mutating func update(discovered: [OpenRouterAudioModel], retaining identifiers: [String]) throws {
        let batch = DesktopTranscription.batchModels(includingDiscovered: discovered)
        // On-device and live entries keep their slots, including models added
        // after launch, in slot order.
        let local = entries.filter { $0.isLocal && !$0.isLive && !hiddenLocal.contains($0.option.id) }.map(\.option)
        let live = entries.filter(\.isLive).map(\.option)
        var seen = Set<String>()
        var options = (batch + local + live).filter { seen.insert($0.id).inserted }
        let available = seen
        for id in identifiers where !seen.contains(id) {
            guard let raw = OpenRouterTranscriptionSelection.modelID(from: id),
                  DesktopTranscription.provider(for: id) != nil else { continue }
            let option = indices[id].map { entries[$0].option }
                ?? ModelCatalog.Option(id: id, displayName: raw, description: nil, latencyTier: .medium)
            options.append(option)
            seen.insert(id)
        }
        let additions = options.filter { indices[$0.id] == nil }
        guard additions.count <= maximumSlots - entries.count else { throw Failure.capacityExceeded }
        for option in additions {
            indices[option.id] = entries.count
            entries.append(Entry(
                option: option, isLive: false, isLocal: false, isAvailable: available.contains(option.id)
            ))
        }
        for index in entries.indices { entries[index].isAvailable = available.contains(entries[index].option.id) }
        for option in options {
            if let index = indices[option.id] { entries[index].option = option }
        }
        visibleIndices = options.compactMap { indices[$0.id] }
    }

    /// Adds an on-device model imported after launch at the end of the
    /// visible list. An identifier that already has a slot keeps it and
    /// becomes visible again. Returns false when the window is full.
    @discardableResult
    public mutating func appendLocal(_ option: ModelCatalog.Option) -> Bool {
        if let index = indices[option.id] {
            guard entries[index].isLocal else { return false }
            hiddenLocal.remove(option.id)
            entries[index].option = option
            entries[index].isAvailable = true
            if !visibleIndices.contains(index) { visibleIndices.append(index) }
            return true
        }
        guard entries.count < maximumSlots else { return false }
        hiddenLocal.remove(option.id)
        indices[option.id] = entries.count
        entries.append(Entry(option: option, isLive: false, isLocal: true, isAvailable: true))
        visibleIndices.append(entries.count - 1)
        return true
    }

    /// Hides an on-device model that was removed; its slot identity stays.
    public mutating func hideLocal(_ identifier: String) {
        guard let index = indices[identifier], entries[index].isLocal, !entries[index].isLive else { return }
        hiddenLocal.insert(identifier)
        entries[index].isAvailable = false
        visibleIndices.removeAll { $0 == index }
    }
}
