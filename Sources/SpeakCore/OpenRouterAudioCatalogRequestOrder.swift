import Foundation

/// A process-wide ordinal orders request starts even when wall-clock timestamps are equal or move backwards.
/// Successful snapshots carry the order, so coordination needs constant memory rather than a growing URL registry.
struct OpenRouterAudioCatalogRequestOrder: Codable, Sendable {
    let processID: UUID
    let ordinal: UInt64
    let startedAt: Date

    @MainActor private static var currentProcessID = UUID()
    @MainActor private static var nextOrdinal: UInt64 = 0

    @MainActor
    static func begin(at date: Date) -> Self {
        if nextOrdinal == .max {
            currentProcessID = UUID()
            nextOrdinal = 0
        }
        nextOrdinal += 1
        return Self(processID: currentProcessID, ordinal: nextOrdinal, startedAt: date)
    }

    func succeeds(_ snapshot: OpenRouterAudioCatalogSnapshot) -> Bool {
        if let previous = snapshot.requestOrder, previous.processID == processID {
            return ordinal > previous.ordinal
        }
        // Across launches (and for legacy caches), never replace a snapshot saved after this request began.
        return startedAt >= snapshot.updatedAt
    }
}
