import Foundation
import SpeakCore

/// Stable native event identities, independent of picker ordering and discovery retirement.
/// Existing slots never change their model ID or mode for this instance's lifetime.
public struct DesktopModelSlots: Sendable {
    public struct Entry: Sendable {
        public internal(set) var option: ModelCatalog.Option
        public let isLive: Bool
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
    private let maximumSlots: Int

    public init(live: [ModelCatalog.Option], maximumSlots: Int = 10_000) {
        let batch = DesktopTranscription.batchModels
        let liveIDs = Set(live.map(\.id))
        var seen = Set<String>()
        initial = (batch + live).filter { seen.insert($0.id).inserted }
        entries = initial.map { Entry(option: $0, isLive: liveIDs.contains($0.id), isAvailable: true) }
        indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.option.id, $0.offset) })
        visibleIndices = Array(entries.indices)
        self.maximumSlots = max(entries.count, maximumSlots)
    }

    /// The caller supplies a canonical visible projection. Retained valid dynamic
    /// selections stay visible even when absent from the latest catalogue.
    /// Capacity failures are atomic: no partially added identity slots escape.
    public mutating func update(discovered: [OpenRouterAudioModel], retaining identifiers: [String]) throws {
        let batch = DesktopTranscription.batchModels(includingDiscovered: discovered)
        let live = initial.filter { indices[$0.id].map { entries[$0].isLive } == true }
        var seen = Set<String>()
        var options = (batch + live).filter { seen.insert($0.id).inserted }
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
            entries.append(Entry(option: option, isLive: false, isAvailable: available.contains(option.id)))
        }
        for index in entries.indices { entries[index].isAvailable = available.contains(entries[index].option.id) }
        for option in options {
            if let index = indices[option.id] { entries[index].option = option }
        }
        visibleIndices = options.compactMap { indices[$0.id] }
    }
}
