import Foundation

/// A round revision or a dated deletion. Deletions remain available for offline peers.
public struct ModelComparisonRevision: Codable, Equatable, Sendable {
    public let id: UUID
    public let updatedAt: Date
    public let round: ModelComparisonRound?

    public init(round: ModelComparisonRound) {
        id = round.id
        updatedAt = round.updatedAt
        self.round = round
    }

    public init(deleting id: UUID, at date: Date) {
        self.id = id
        updatedAt = date
        round = nil
    }

    public var isValid: Bool {
        guard let round else { return true }
        return round.isValid && round.id == id && round.updatedAt == updatedAt
    }
}
