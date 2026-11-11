import Foundation
import SpeakCore
import SpeakDesktop

let comparisonFileSaved = "Comparison results saved. Review or rank the results below."
let comparisonBatchPaused =
    "Batch paused. Judge this round, then choose Next file. No further requests start automatically."

func comparisonHistoryNotice(_ saveToHistory: Bool) -> String {
    saveToHistory
        ? "Raw transcripts only. No insertion or post-processing. Save results to History is on: "
            + "each model's result, including failures, is added to History.\n"
        : "Raw transcripts only. No insertion, post-processing or History changes.\n"
}

extension DesktopHostController {
    func setComparisonSavesToHistory(_ enabled: Bool) async {
        guard !closed else { return }
        do {
            try await loadComparisonStore().setSavesResultsToHistory(enabled)
            comparisonStatus(enabled
                ? "Save results to History is on. Each finished round adds one History item per model."
                : "Save results to History is off.")
        } catch {
            comparisonStatus("Save results to History was not changed: \(error.localizedDescription)")
        }
    }

    /// Writes each lane of a finished round to History when the user opted in.
    /// A History failure never loses the saved comparison; the returned
    /// sentence is appended to the caller's status so it stays visible.
    func saveComparisonToHistory(_ round: ModelComparisonRound) async -> String {
        guard !closed, let comparisons, await comparisons.savesResultsToHistory() else { return "" }
        do {
            for record in DesktopComparisonHistory.records(for: round) {
                try await saveRecord(record)
            }
            return " Results added to History."
        } catch {
            return " Adding the results to History failed: \(error.localizedDescription)"
        }
    }
}
