import SpeakCore

struct DesktopComparisonRoundPresentation {
    let revealed: Bool
    let judgeable: Bool
    let instruction: String

    init(round: ModelComparisonRound?, busy: Bool) {
        guard let round else {
            revealed = false; judgeable = false; instruction = ""
            return
        }
        let usable = round.entries.filter { !$0.didFail }.count
        revealed = round.isJudged || (!busy && usable < 2)
        judgeable = !busy && !round.isJudged && usable >= 2
        instruction = !busy && !round.isJudged && usable < 2
            ? "Fewer than two models produced a transcript. Evidence is revealed without inventing a ranking.\n" : ""
    }

    func suffix(for entry: ModelComparisonEntry, in round: ModelComparisonRound) -> String {
        guard revealed else { return "" }
        let rank = round.rank(for: entry.id).map { "rank \($0)" } ?? "unranked"
        return " - \(entry.modelDisplayName) (\(rank))"
    }
}
