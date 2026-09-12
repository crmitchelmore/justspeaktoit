import Foundation

/// JSON and Markdown renderings of comparison rounds and the scoreboard, for
/// bug reports and sharing. Exports carry the sample's identity (name, hash,
/// duration) but never the audio itself.
public enum ModelComparisonExport {
    public struct Document: Codable, Sendable {
        public let schemaVersion: Int
        public let exportedAt: Date
        public let rounds: [ModelComparisonRound]
        public let scoreboard: [ScoreRow]

        public init(exportedAt: Date, rounds: [ModelComparisonRound]) {
            schemaVersion = ModelComparisonRound.schemaVersion
            self.exportedAt = exportedAt
            self.rounds = rounds
            scoreboard = ModelComparisonScoreboard.scores(for: rounds).map(ScoreRow.init)
        }
    }

    /// A scoreboard line in a stable, Codable shape.
    public struct ScoreRow: Codable, Sendable {
        public let modelID: String
        public let modelDisplayName: String
        public let providerDisplayName: String
        public let roundsPlayed: Int
        public let wins: Int
        public let meanRank: Double?
        public let failures: Int
        public let meanTimeToFirstPartialMs: Int?
        public let meanTimeToFinalMs: Int?
        public let meanEstimatedCostUSD: Decimal?

        init(_ score: ModelComparisonScore) {
            modelID = score.modelID
            modelDisplayName = score.modelDisplayName
            providerDisplayName = score.providerDisplayName
            roundsPlayed = score.roundsPlayed
            wins = score.wins
            meanRank = score.meanRank
            failures = score.failures
            meanTimeToFirstPartialMs = score.meanTimeToFirstPartialMs
            meanTimeToFinalMs = score.meanTimeToFinalMs
            meanEstimatedCostUSD = score.meanEstimatedCostUSD
        }
    }

    // MARK: JSON

    public static func json(rounds: [ModelComparisonRound], exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(exportedAt: exportedAt, rounds: rounds))
    }

    // MARK: Markdown

    public static func markdown(round: ModelComparisonRound) -> String {
        var lines: [String] = []
        lines.append("## Comparison round \(escape(round.sample.name))")
        lines.append("")
        lines.append("- Recorded: \(iso8601.string(from: round.createdAt))")
        lines.append("- Input: \(round.inputMode.displayName)")
        lines.append("- Sample: \(escape(sampleDescription(round.sample)))")
        if let language = round.language, !language.isEmpty {
            lines.append("- Language: \(escape(language))")
        }
        lines.append("- Judged: \(round.judgedAt.map(iso8601.string(from:)) ?? "not yet")")
        lines.append("")
        lines.append("| Rank | Blind | Model | Provider | First partial | Final | Est. cost | Transcript |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        for entry in resultOrder(round) {
            lines.append(entryRow(entry, in: round))
        }
        return lines.joined(separator: "\n")
    }

    public static func markdown(rounds: [ModelComparisonRound], exportedAt: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("# Compare Models")
        lines.append("")
        lines.append("Exported \(iso8601.string(from: exportedAt)). \(rounds.count) round(s).")
        lines.append("")
        lines.append(scoreboardMarkdown(rounds: rounds))
        for round in rounds.sorted(by: { $0.createdAt > $1.createdAt }) {
            lines.append("")
            lines.append(markdown(round: round))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func scoreboardMarkdown(rounds: [ModelComparisonRound]) -> String {
        let scores = ModelComparisonScoreboard.scores(for: rounds)
        var lines: [String] = []
        lines.append("## Scoreboard")
        lines.append("")
        lines.append(
            "| Model | Provider | Rounds | Wins | Mean rank | Failures | First partial | Final | Est. cost/run |"
        )
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for score in scores {
            lines.append(
                "| \(escape(score.modelDisplayName)) | \(escape(score.providerDisplayName)) | \(score.roundsPlayed) "
                    + "| \(score.wins) | \(score.meanRank.map { String(format: "%.2f", $0) } ?? "–") "
                    + "| \(score.failures) | \(formatMs(score.meanTimeToFirstPartialMs)) "
                    + "| \(formatMs(score.meanTimeToFinalMs)) | \(formatCost(score.meanEstimatedCostUSD)) |"
            )
        }
        if scores.isEmpty {
            lines.append("| – | – | 0 | 0 | – | 0 | – | – | – |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// A fresh formatter per export: `ISO8601DateFormatter` is not Sendable,
    /// and exports are rare enough that sharing one buys nothing.
    static var iso8601: ISO8601DateFormatter { ISO8601DateFormatter() }

    /// Judged rounds list by rank; unjudged rounds keep the blind order.
    static func resultOrder(_ round: ModelComparisonRound) -> [ModelComparisonEntry] {
        guard round.isJudged else { return round.entriesInBlindOrder }
        return round.entries.sorted { lhs, rhs in
            (round.rank(for: lhs.id) ?? .max) < (round.rank(for: rhs.id) ?? .max)
        }
    }

    private static func entryRow(_ entry: ModelComparisonEntry, in round: ModelComparisonRound) -> String {
        let rank = round.rank(for: entry.id).map(String.init) ?? "–"
        let transcript = entry.didFail
            ? "_Failed: \(escape(entry.errorDescription ?? "unknown error"))_"
            : escape(entry.transcript)
        return "| \(rank) | \(round.blindLabel(for: entry.id)) | \(escape(entry.modelDisplayName)) "
            + "| \(escape(entry.providerDisplayName)) | \(formatMs(entry.timeToFirstPartialMs)) "
            + "| \(formatMs(entry.timeToFinalMs)) | \(formatCost(entry.estimatedCostUSD)) | \(transcript) |"
    }

    static func sampleDescription(_ sample: ModelComparisonSample) -> String {
        var parts = [String(format: "%.1f s", sample.durationSeconds)]
        if let hash = sample.contentHash {
            parts.append("sha256 \(hash.prefix(12))…")
        }
        return parts.joined(separator: ", ")
    }

    static func formatMs(_ value: Int?) -> String {
        value.map(SessionLatencyMetrics.formattedMilliseconds) ?? "–"
    }

    static func formatCost(_ value: Decimal?) -> String {
        value.map(TranscriptionPricing.formatted) ?? "–"
    }

    /// Keeps a transcript on one table row and stops it breaking the table.
    static func escape(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let syntax = Set("\\`*_{}[]<>#!|")
        return flattened.map { syntax.contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}
