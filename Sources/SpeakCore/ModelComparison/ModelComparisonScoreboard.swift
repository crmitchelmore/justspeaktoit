import Foundation

/// One model's standing across every judged round it took part in.
public struct ModelComparisonScore: Identifiable, Hashable, Sendable {
    public var id: String { modelID }

    public let modelID: String
    public let modelDisplayName: String
    public let providerDisplayName: String
    /// Judged rounds in which this model produced a transcript.
    public let roundsPlayed: Int
    /// Rounds ranked first.
    public let wins: Int
    public let meanRank: Double?
    /// Rounds in which the model failed to transcribe (not counted as played).
    public let failures: Int
    public let meanTimeToFirstPartialMs: Int?
    public let meanTimeToFinalMs: Int?
    public let meanEstimatedCostUSD: Decimal?

    public init(
        modelID: String,
        modelDisplayName: String,
        providerDisplayName: String,
        roundsPlayed: Int,
        wins: Int,
        meanRank: Double?,
        failures: Int,
        meanTimeToFirstPartialMs: Int?,
        meanTimeToFinalMs: Int?,
        meanEstimatedCostUSD: Decimal?
    ) {
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.providerDisplayName = providerDisplayName
        self.roundsPlayed = roundsPlayed
        self.wins = wins
        self.meanRank = meanRank
        self.failures = failures
        self.meanTimeToFirstPartialMs = meanTimeToFirstPartialMs
        self.meanTimeToFinalMs = meanTimeToFinalMs
        self.meanEstimatedCostUSD = meanEstimatedCostUSD
    }

    public var winRate: Double? {
        guard roundsPlayed > 0 else { return nil }
        return Double(wins) / Double(roundsPlayed)
    }
}

/// Aggregates judged rounds into a per-model scoreboard.
///
/// Only judged rounds contribute rank statistics. Latency and cost are
/// averaged over every round where the model produced a value, judged or
/// not, because those measurements do not depend on the user's verdict.
public enum ModelComparisonScoreboard {
    public static func scores(for rounds: [ModelComparisonRound]) -> [ModelComparisonScore] {
        var accumulators: [String: Accumulator] = [:]
        for round in rounds {
            for entry in round.entries {
                var accumulator = accumulators[entry.modelID] ?? Accumulator(entry: entry)
                accumulator.absorb(entry: entry, in: round)
                accumulators[entry.modelID] = accumulator
            }
        }
        return accumulators.values
            .map { $0.score }
            .sorted(by: Self.standingOrder)
    }

    /// Best standing first: lowest mean rank, then most wins, then most
    /// rounds, then name — so a model with one lucky win does not outrank a
    /// consistent performer with more evidence.
    static func standingOrder(_ lhs: ModelComparisonScore, _ rhs: ModelComparisonScore) -> Bool {
        switch (lhs.meanRank, rhs.meanRank) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
        if lhs.wins != rhs.wins { return lhs.wins > rhs.wins }
        if lhs.roundsPlayed != rhs.roundsPlayed { return lhs.roundsPlayed > rhs.roundsPlayed }
        return lhs.modelDisplayName.localizedCaseInsensitiveCompare(rhs.modelDisplayName) == .orderedAscending
    }

    private struct Accumulator {
        let modelID: String
        var modelDisplayName: String
        var providerDisplayName: String
        var roundsPlayed = 0
        var wins = 0
        var rankTotal = 0
        var failures = 0
        var firstPartialSamples: [Int] = []
        var finalSamples: [Int] = []
        var costSamples: [Decimal] = []

        init(entry: ModelComparisonEntry) {
            modelID = entry.modelID
            modelDisplayName = entry.modelDisplayName
            providerDisplayName = entry.providerDisplayName
        }

        mutating func absorb(entry: ModelComparisonEntry, in round: ModelComparisonRound) {
            // Later rounds carry the freshest display names.
            modelDisplayName = entry.modelDisplayName
            providerDisplayName = entry.providerDisplayName
            if entry.didFail {
                failures += 1
                return
            }
            if let first = entry.timeToFirstPartialMs { firstPartialSamples.append(first) }
            if let final = entry.timeToFinalMs { finalSamples.append(final) }
            if let cost = entry.estimatedCostUSD { costSamples.append(cost) }
            guard let rank = round.rank(for: entry.id) else { return }
            roundsPlayed += 1
            rankTotal += rank
            if rank == 1 { wins += 1 }
        }

        var score: ModelComparisonScore {
            ModelComparisonScore(
                modelID: modelID,
                modelDisplayName: modelDisplayName,
                providerDisplayName: providerDisplayName,
                roundsPlayed: roundsPlayed,
                wins: wins,
                meanRank: roundsPlayed > 0 ? Double(rankTotal) / Double(roundsPlayed) : nil,
                failures: failures,
                meanTimeToFirstPartialMs: Self.mean(firstPartialSamples),
                meanTimeToFinalMs: Self.mean(finalSamples),
                meanEstimatedCostUSD: Self.mean(costSamples)
            )
        }

        private static func mean(_ samples: [Int]) -> Int? {
            guard !samples.isEmpty else { return nil }
            return Int((Double(samples.reduce(0, +)) / Double(samples.count)).rounded())
        }

        private static func mean(_ samples: [Decimal]) -> Decimal? {
            guard !samples.isEmpty else { return nil }
            return samples.reduce(Decimal.zero, +) / Decimal(samples.count)
        }
    }
}
