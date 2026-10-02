import Foundation

/// A process-wide ordinal orders request starts even when wall-clock timestamps are equal or move backwards.
/// Successful snapshots carry the order, so coordination needs constant memory rather than a growing URL registry.
struct OpenRouterAudioCatalogRequestOrder: Codable, Sendable {
    let processID: UUID
    let ordinal: UInt64
    let startedAt: Date

    private final class Sequence: @unchecked Sendable {
        let lock = NSLock()
        var processID = UUID()
        var ordinal: UInt64 = 0
    }
    private static let sequence = Sequence()

    static func begin(at date: Date) -> Self {
        sequence.lock.withLock {
            if sequence.ordinal == .max {
                sequence.processID = UUID()
                sequence.ordinal = 0
            }
            sequence.ordinal += 1
            return Self(processID: sequence.processID, ordinal: sequence.ordinal, startedAt: date)
        }
    }

    func succeeds(_ snapshot: OpenRouterAudioCatalogSnapshot) -> Bool {
        if let previous = snapshot.requestOrder, previous.processID == processID {
            return ordinal > previous.ordinal
        }
        // Across launches (and for legacy caches), never replace a snapshot saved after this request began.
        return startedAt >= snapshot.updatedAt
    }
}
