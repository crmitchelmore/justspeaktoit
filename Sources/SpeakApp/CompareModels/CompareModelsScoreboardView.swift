import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

/// Per-model standings across every judged round, plus the round history.
struct CompareModelsScoreboardView: View {
    @ObservedObject var controller: CompareModelsController
    @ObservedObject private var store: ComparisonRoundStore

    init(controller: CompareModelsController) {
        self.controller = controller
        store = controller.store
    }

    var body: some View {
        SettingsCard(title: "Scoreboard", systemImage: "trophy", tint: .brandAccentWarm) {
            VStack(alignment: .leading, spacing: 12) {
                if store.rounds.isEmpty {
                    Text("No rounds yet. Judge a few comparisons and the models that win for you "
                        + "will rise to the top.")
                        .foregroundStyle(.secondary)
                } else {
                    scoreboardTable
                    HStack {
                        CompareModelsExportMenu(
                            controller: controller, rounds: store.rounds, label: "Export everything"
                        )
                        Spacer()
                        Text("Costs are list-price estimates (reviewed \(TranscriptionPricing.lastReviewed)).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    roundHistory
                }
                if let error = store.persistenceError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var scores: [ModelComparisonScore] { ModelComparisonScoreboard.scores(for: store.rounds) }

    private var scoreboardTable: some View {
        Table(scores) {
            TableColumn("Model") { score in
                VStack(alignment: .leading, spacing: 0) {
                    Text(score.modelDisplayName)
                    Text(score.providerDisplayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 160)
            TableColumn("Rounds") { score in Text("\(score.roundsPlayed)") }.width(60)
            TableColumn("Wins") { score in Text("\(score.wins)") }.width(50)
            TableColumn("Mean rank") { score in
                Text(score.meanRank.map { String(format: "%.2f", $0) } ?? "–")
            }
            .width(80)
            TableColumn("Failures") { score in Text("\(score.failures)") }.width(70)
            TableColumn("First partial") { score in
                Text(score.meanTimeToFirstPartialMs.map(SessionLatencyMetrics.formattedMilliseconds) ?? "–")
            }
            .width(90)
            TableColumn("Final") { score in
                Text(score.meanTimeToFinalMs.map(SessionLatencyMetrics.formattedMilliseconds) ?? "–")
            }
            .width(70)
            TableColumn("Est. cost/run") { score in
                Text(score.meanEstimatedCostUSD.map(TranscriptionPricing.formatted) ?? "–")
            }
            .width(90)
        }
        .frame(minHeight: CGFloat(min(max(scores.count, 1), 8)) * 36 + 30)
        .accessibilityIdentifier("compareModelsScoreboard")
    }

    private var roundHistory: some View {
        DisclosureGroup("Rounds (\(store.rounds.count))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.rounds) { round in
                    CompareModelsRoundRow(controller: controller, round: round)
                }
            }
            .padding(.top, 4)
        }
    }
}

struct CompareModelsRoundRow: View {
    @ObservedObject var controller: CompareModelsController
    let round: ModelComparisonRound

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(summary).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            CompareModelsExportMenu(controller: controller, rounds: [round], label: "Export")
                .controlSize(.small)
            Button(role: .destructive) {
                controller.deleteRound(id: round.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this round")
        }
    }

    private var summary: String {
        let winner = round.entries.first { round.rank(for: $0.id) == 1 }
        let verdict = winner.map { "Winner: \($0.modelDisplayName)" } ?? "Not judged"
        return "\(round.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(verdict)"
    }

    private var detail: String {
        "\(round.inputMode.displayName) · \(round.sample.name) · \(round.entries.count) models"
            + (round.originPlatform == "macos" ? "" : " · from \(round.originPlatform)")
    }
}

/// Copy or save a round (or the whole scoreboard) as JSON or Markdown.
struct CompareModelsExportMenu: View {
    @ObservedObject var controller: CompareModelsController
    let rounds: [ModelComparisonRound]
    let label: String

    var body: some View {
        Menu(label) {
            Button("Copy as Markdown") { controller.copyToPasteboard(controller.exportMarkdown(rounds: rounds)) }
            Button("Copy as JSON") {
                if let json = controller.exportJSON(rounds: rounds) { controller.copyToPasteboard(json) }
            }
            Divider()
            Button("Save Markdown…") {
                Task { await controller.save(controller.exportMarkdown(rounds: rounds),
                                             suggestedName: "\(baseName).md", type: .plainText) }
            }
            Button("Save JSON…") {
                guard let json = controller.exportJSON(rounds: rounds) else { return }
                Task { await controller.save(json, suggestedName: "\(baseName).json", type: .json) }
            }
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var baseName: String {
        rounds.count == 1
            ? "compare-models-round-\(rounds[0].id.uuidString.prefix(8))"
            : "compare-models-scoreboard"
    }
}
