#if os(iOS)
import SpeakCore
import SwiftUI

/// Reviews learned corrections (F48, #1651): candidates waiting to reach the
/// promotion threshold, and the rules already applied to transcripts.
struct LearnedCorrectionsView: View {
    @ObservedObject private var engine = IOSLearnedCorrections.shared.engine
    @ObservedObject private var lexicon = IOSLearnedCorrections.shared.lexicon
    @State private var errorMessage: String?

    private var learnedRules: [PersonalLexiconRule] {
        lexicon.rules.filter { $0.source == .automatic }
    }

    var body: some View {
        List {
            Section {
                if learnedRules.isEmpty {
                    Text("No learned corrections yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(learnedRules) { rule in
                    ruleRow(rule)
                }
                .onDelete { offsets in
                    let ids = offsets.map { learnedRules[$0].id }
                    run { for id in ids { try await lexicon.deleteRule(id: id) } }
                }
            } header: {
                Text("Applied to Transcripts")
            } footer: {
                Text("These replace the misheard words in every new transcript.")
            }

            Section {
                if engine.candidates.isEmpty {
                    Text("No candidates. Edit a transcript the keyboard inserted to start one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(engine.candidates) { candidate in
                    candidateRow(candidate)
                }
                if !engine.candidates.isEmpty {
                    Button("Clear All Candidates", role: .destructive) {
                        run { try await engine.clearAllCandidates() }
                    }
                    .accessibilityIdentifier("autoCorrectionsClearAll")
                }
            } header: {
                Text("Candidates")
            } footer: {
                Text("A candidate becomes a correction once you make the same edit enough times.")
            }
        }
        .navigationTitle("Learned Corrections")
        .task {
            await IOSLearnedCorrections.shared.ingestKeyboardObservations()
        }
        .alert(
            "Couldn't Update Corrections",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button("OK") { errorMessage = nil }.accessibilityIdentifier("learnedCorrectionsErrorOK") },
            message: { Text(errorMessage ?? "") }
        )
    }

    private func ruleRow(_ rule: PersonalLexiconRule) -> some View {
        HStack {
            correctionLabel(original: rule.aliases.joined(separator: ", "), corrected: rule.canonical)
            Spacer()
            Button {
                run { try await lexicon.deleteRule(id: rule.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .accessibilityLabel("Remove correction \(rule.canonical)")
            .accessibilityIdentifier("learnedCorrectionDelete-\(rule.id)")
        }
    }

    private func candidateRow(_ candidate: AutoCorrectionCandidate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                correctionLabel(original: candidate.original, corrected: candidate.corrected)
                Text("Seen \(candidate.seenCount)×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                run { try await engine.promoteCandidate(candidate) }
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add as correction rule: \(candidate.original) to \(candidate.corrected)")
            .accessibilityIdentifier("autoCorrectionPromote-\(candidate.id)")

            Button {
                run { try await engine.dismissCandidate(id: candidate.id) }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss candidate \(candidate.original)")
            .accessibilityIdentifier("autoCorrectionDismiss-\(candidate.id)")
        }
    }

    private func correctionLabel(original: String, corrected: String) -> some View {
        HStack(spacing: 6) {
            Text(original)
                .strikethrough()
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(corrected)
                .fontWeight(.medium)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(original) becomes \(corrected)")
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
