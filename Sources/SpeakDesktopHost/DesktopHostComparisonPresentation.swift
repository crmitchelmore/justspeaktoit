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

extension DesktopHostController {
    func comparisonRoundDetail(
        _ round: ModelComparisonRound, state: DesktopComparisonRoundPresentation, reference: ModelComparisonEntry?
    ) async -> String {
        var detail = "\n\(round.sample.name) - \(round.inputMode.displayName)\n" + state.instruction
        if let reference {
            detail += "Word differences against Result \(round.blindLabel(for: reference.id)): "
                + "[+added] / [-removed]. Original transcripts are preserved below.\n"
        }
        for entry in round.entriesInBlindOrder {
            detail += "\nResult \(round.blindLabel(for: entry.id))\(state.suffix(for: entry, in: round))\n"
            // Provider errors may name the model, so blind failures hide their raw messages.
            if entry.didFail {
                detail += (state.revealed ? entry.errorDescription ?? "Failed" : "Model failed.") + "\n"
            }
            detail += entry.transcript + "\n"
            if let reference, reference.id != entry.id, !entry.didFail {
                detail += await comparisonWords.diff(
                    reference: reference.transcript, candidate: entry.transcript, id: entry.id
                ) + "\n"
            }
            if state.revealed {
                if let partial = entry.timeToFirstPartialMs { detail += "First partial: \(partial) ms. " }
                if let final = entry.timeToFinalMs { detail += "Finalization: \(final) ms. " }
                if let cost = entry.estimatedCostUSD { detail += "Estimated cost: USD \(cost)." }
                detail += "\n"
            }
        }
        return detail
    }
}
