import SpeakCore
import SwiftUI

/// The in-progress or just-judged round: unlabelled transcript columns in
/// blind order with word-level differences highlighted, rank pickers, and
/// the reveal once the ranking is saved.
struct CompareModelsRoundView: View {
    @ObservedObject var controller: CompareModelsController
    let round: ModelComparisonRound

    private var isRevealed: Bool { controller.phase == .revealed }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            roundHeader
            columns
            footer
        }
    }

    private var roundHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isRevealed ? "Results" : "Judge blind")
                    .font(.headline)
                Text("\(round.inputMode.displayName) · \(round.sample.name) · \(round.entries.count) models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.phase == .judging || isRevealed {
                Picker("Diff against", selection: Binding(
                    get: { controller.referenceEntryID ?? round.entriesInBlindOrder.first?.id },
                    set: { controller.referenceEntryID = $0 }
                )) {
                    ForEach(round.entriesInBlindOrder) { entry in
                        Text(round.blindLabel(for: entry.id)).tag(Optional(entry.id))
                    }
                }
                .frame(maxWidth: 200)
            }
        }
    }

    private var columns: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(round.entriesInBlindOrder) { entry in
                    CompareModelsColumnView(
                        controller: controller,
                        round: round,
                        entry: entry,
                        referenceText: referenceText(excluding: entry.id),
                        isRevealed: isRevealed
                    )
                    .frame(width: 280, alignment: .top)
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// The reference column's text, or `nil` for the reference column itself
    /// so it renders plain.
    private func referenceText(excluding entryID: UUID) -> String? {
        let referenceID = controller.referenceEntryID ?? round.entriesInBlindOrder.first?.id
        guard let referenceID, referenceID != entryID else { return nil }
        return controller.liveTranscripts[referenceID] ?? round.entries.first { $0.id == referenceID }?.transcript
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            switch controller.phase {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Opening sessions…")
            case .streaming:
                Button {
                    Task { await controller.stopStreaming() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("compareModelsStop")
                Button("Cancel") { Task { await controller.cancelStreaming() } }
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Waiting for transcripts…")
                Button("Cancel") { Task { await controller.cancelStreaming() } }
            case .judging:
                Button("Submit ranking") { controller.submitRanking() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.isRankingComplete)
                    .accessibilityIdentifier("compareModelsSubmitRanking")
                Button("Discard round") { Task { await controller.discardRound() } }
                Text("Give every column a different rank; 1 is best.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .revealed:
                Button(controller.queuedFiles.isEmpty ? "Done" : "Next file") {
                    Task { await controller.finishRound() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("compareModelsDone")
                CompareModelsExportMenu(controller: controller, rounds: [round], label: "Export round")
                if !controller.queuedFiles.isEmpty {
                    Text("\(controller.queuedFiles.count) file(s) still queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .idle:
                EmptyView()
            }
        }
    }
}

/// One transcript column. Blind while judging: only its letter, the text and
/// (for the non-reference columns) the highlighted differences.
struct CompareModelsColumnView: View {
    @ObservedObject var controller: CompareModelsController
    let round: ModelComparisonRound
    let entry: ModelComparisonEntry
    let referenceText: String?
    let isRevealed: Bool

    @State private var diffTokens: [TranscriptWordDiff.Token]?

    private struct DiffInput: Equatable {
        let reference: String?
        let candidate: String
    }

    private var text: String {
        controller.liveTranscripts[entry.id] ?? entry.transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader
            if let error = entry.errorDescription, text.isEmpty {
                Text(isRevealed ? error : "This model could not transcribe the recording.")
                    .font(.caption).foregroundStyle(.red)
            } else if text.isEmpty {
                Text(controller.phase == .streaming ? "Listening…" : "Transcribing…")
                    .foregroundStyle(.tertiary)
            } else {
                highlightedTranscript
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isRevealed { metrics }
            if controller.phase == .judging {
                rankPicker
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: rank == 1 && isRevealed ? 2 : 1)
        )
        .task(id: DiffInput(reference: referenceText, candidate: text)) {
            diffTokens = nil
            guard let referenceText else { return }
            let candidate = text
            let tokens = await Task.detached(priority: .userInitiated) {
                TranscriptWordDiff.diff(reference: referenceText, candidate: candidate)
            }.value
            guard !Task.isCancelled else { return }
            diffTokens = tokens
        }
        .accessibilityIdentifier("compareModelsColumn-\(round.blindLabel(for: entry.id))")
    }

    private var rank: Int? { round.rank(for: entry.id) ?? controller.pendingRanks[entry.id] }

    private var borderColor: Color {
        if isRevealed, rank == 1 { return .brandAccentWarm }
        return Color.secondary.opacity(0.3)
    }

    private var columnHeader: some View {
        HStack {
            Text(round.blindLabel(for: entry.id))
                .font(.title3.bold())
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.brandLagoon.opacity(0.15)))
            if isRevealed {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.modelDisplayName).font(.subheadline.weight(.semibold))
                    Text(entry.providerDisplayName).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Model hidden").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let rank, isRevealed {
                Text("#\(rank)").font(.headline).foregroundStyle(rank == 1 ? Color.brandAccentWarm : .secondary)
            }
        }
    }

    private var highlightedTranscript: Text {
        guard let diffTokens else { return Text(text) }
        return diffTokens
            .reduce(Text("")) { partial, token in
                partial + Self.styled(token) + Text(" ")
            }
    }

    private static func styled(_ token: TranscriptWordDiff.Token) -> Text {
        switch token.kind {
        case .equal:
            return Text(token.text)
        case .inserted:
            return Text(token.text).foregroundColor(.orange).bold()
        case .deleted:
            return Text(token.text).foregroundColor(.secondary).strikethrough()
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            if let first = entry.timeToFirstPartialMs {
                metric("First partial", SessionLatencyMetrics.formattedMilliseconds(first))
            }
            if let final = entry.timeToFinalMs {
                metric("Final", SessionLatencyMetrics.formattedMilliseconds(final))
            }
            if let cost = entry.estimatedCostUSD {
                metric("Est. cost", TranscriptionPricing.formatted(cost))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
            Text(value).font(.caption.weight(.medium)).foregroundStyle(.primary)
        }
    }

    private var rankPicker: some View {
        Picker("Rank", selection: Binding(
            get: { controller.pendingRanks[entry.id] ?? 0 },
            set: { controller.setRank($0 == 0 ? nil : $0, for: entry.id) }
        )) {
            Text("Unranked").tag(0)
            ForEach(1...round.entries.count, id: \.self) { rank in
                Text("Rank \(rank)").tag(rank)
            }
        }
        .accessibilityIdentifier("compareModelsRank-\(round.blindLabel(for: entry.id))")
    }
}
