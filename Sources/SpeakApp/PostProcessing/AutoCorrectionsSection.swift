import SpeakCore
import SwiftUI

/// The Auto-Corrections card: the learning toggle, the promotion threshold and
/// the candidate corrections waiting to be promoted or dismissed.
struct AutoCorrectionsSection: View {
  @EnvironmentObject private var autoCorrectionTracker: AutoCorrectionTracker
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.appVisualDensity) private var density
  let onError: (Error) -> Void

  var body: some View {
    SpeakDensityCard(title: "Auto-Corrections", systemImage: "wand.and.stars", tint: .brandAccent) {
      Toggle("", isOn: $settings.autoCorrectionsEnabled)
        .labelsHidden()
        .accessibilityLabel("Learn corrections automatically")
        .accessibilityIdentifier("autoCorrectionsToggle")
    } content: {
      Text("Learn from your edits after transcription")
        .font(.caption)
        .foregroundStyle(.secondary)

      if settings.autoCorrectionsEnabled {
        learningOptions
      }
    }
  }

  private var learningOptions: some View {
    VStack(alignment: .leading, spacing: density.inlineSpacing) {
      HStack {
        Text("Promotion threshold:")
          .font(.callout)
        Stepper(
          "\(settings.autoCorrectionsPromotionThreshold) occurrences",
          value: $settings.autoCorrectionsPromotionThreshold,
          in: AutoCorrectionLearningPolicy.promotionThresholdRange
        )
        .font(.callout)
      }

      if !autoCorrectionTracker.candidates.isEmpty {
        Divider()
        candidateList
      } else if autoCorrectionTracker.isMonitoring {
        HStack(spacing: 8) {
          ProgressView()
            .scaleEffect(0.7)
          Text("Monitoring for corrections…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var candidateList: some View {
    VStack(alignment: .leading, spacing: density.inlineSpacing) {
      HStack {
        Text("Candidate Corrections")
          .font(.subheadline.bold())
        Text("(\(autoCorrectionTracker.candidates.count))")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        if !autoCorrectionTracker.candidates.isEmpty {
          Button("Clear All", role: .destructive) {
            run { try await autoCorrectionTracker.clearAllCandidates() }
          }
          .font(.caption)
          .buttonStyle(.borderless)
        }
      }

      ForEach(autoCorrectionTracker.candidates.prefix(10)) { candidate in
        candidateRow(candidate)
      }

      if autoCorrectionTracker.candidates.count > 10 {
        Text("...and \(autoCorrectionTracker.candidates.count - 10) more")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func candidateRow(_ candidate: AutoCorrectionCandidate) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(candidate.original)
            .strikethrough()
            .foregroundStyle(.secondary)
          Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Text(candidate.corrected)
            .fontWeight(.medium)
        }
        .font(.callout)

        HStack(spacing: 8) {
          Text("Seen \(candidate.seenCount)×")
            .font(.caption2)
            .foregroundStyle(.secondary)
          if !candidate.sourceApps.isEmpty {
            Text("in \(candidate.sourceApps.joined(separator: ", "))")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }

      Spacer()

      candidateActions(candidate)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private func candidateActions(_ candidate: AutoCorrectionCandidate) -> some View {
    HStack(spacing: 8) {
      Button {
        run { try await autoCorrectionTracker.promoteCandidate(candidate) }
      } label: {
        Image(systemName: "checkmark.circle")
      }
      .buttonStyle(.borderless)
      .help("Add as correction rule")
      .accessibilityLabel("Add as correction rule: \(candidate.original) to \(candidate.corrected)")
      .accessibilityIdentifier("autoCorrectionPromote-\(candidate.id)")

      Button {
        run { try await autoCorrectionTracker.dismissCandidate(id: candidate.id) }
      } label: {
        Image(systemName: "xmark.circle")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Dismiss")
      .accessibilityLabel("Dismiss candidate \(candidate.original)")
      .accessibilityIdentifier("autoCorrectionDismiss-\(candidate.id)")
    }
  }

  private func run(_ operation: @escaping @MainActor () async throws -> Void) {
    Task {
      do {
        try await operation()
      } catch {
        onError(error)
      }
    }
  }
}
