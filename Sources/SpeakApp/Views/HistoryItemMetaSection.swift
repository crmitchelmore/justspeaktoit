import SpeakCore
import AppKit
import SwiftUI

/// Timings, cost, models and personal corrections for an expanded History row.
struct HistoryItemMetaSection: View {
  @Environment(\.appVisualDensity) private var density
  let item: HistoryItem

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Session Details")
        .font(.subheadline.bold())

      LazyVGrid(columns: metaColumns, alignment: .leading, spacing: 12) {
        metaTile(icon: "bolt.horizontal.circle", title: "Trigger") {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.trigger.gesture.rawValue.capitalized)
            Text("Hotkey: \(item.trigger.hotKeyDescription)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let destination = item.trigger.destinationApplication {
          metaTile(icon: "app", title: "Destination") {
            Text(destination)
          }
        }

        if !item.modelUsages.isEmpty {
          metaTile(icon: "brain.head.profile", title: "Models") {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(item.modelsByPhase, id: \.phase) { group in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text("\(group.phaseLabel):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Text(group.models)
                    .font(.caption)
                }
              }
            }
            .fixedSize(horizontal: false, vertical: true)
          }
        } else if let models = modelsSummary {
          metaTile(icon: "brain.head.profile", title: "Models") {
            Text(models.replacingOccurrences(of: "\n", with: ", "))
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        metaTile(icon: "clock.arrow.circlepath", title: "Timeline") {
          if let start = item.phaseTimestamps.recordingStarted,
            let end = item.phaseTimestamps.outputDelivered {
            let total = end.timeIntervalSince(start)
            Text("Total: \(HistoryRowFormatting.formatDuration(total))")
          } else {
            Text("Recording: \(HistoryRowFormatting.formatDuration(item.recordingDuration))")
          }
        }

        if let cost = item.cost {
          metaTile(icon: "creditcard", title: "Cost") {
            VStack(alignment: .leading, spacing: 4) {
              Text(HistoryRowFormatting.formatCurrency(cost.total, currency: cost.currency))
              if let breakdown = cost.breakdown {
                Text("Input tokens: \(breakdown.inputTokens) • Output: \(breakdown.outputTokens)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      if let summary = item.personalCorrections,
        !(summary.applied.isEmpty && summary.suggestions.isEmpty) {
        personalCorrectionsSection(summary)
      }
    }
  }
}

private extension HistoryItemMetaSection {
  private var metaColumns: [GridItem] {
    [
      GridItem(
        .adaptive(
          minimum: density.isCompact ? 120 : 160,
          maximum: density.isCompact ? 240 : 340
        ),
        spacing: density.isCompact ? density.inlineSpacing : 10,
        alignment: .topLeading
      )
    ]
  }

  private func personalCorrectionsSection(_ summary: PersonalLexiconHistorySummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Corrections")
        .font(.caption.bold())

      if !summary.contextTags.isEmpty {
        Text("Context tags: \(summary.contextTags.joined(separator: ", "))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if let destination = summary.destinationApplication, !destination.isEmpty {
        Text("Destination context: \(destination)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if !summary.applied.isEmpty {
        correctionsList(
          title: "Applied",
          icon: "wand.and.stars",
          color: .green,
          records: summary.applied
        )
      }

      if !summary.suggestions.isEmpty {
        correctionsList(
          title: "Suggestions",
          icon: "hand.raised",
          color: .orange,
          records: summary.suggestions
        )
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
  }

  private func correctionsList(
    title: String,
    icon: String,
    color: Color,
    records: [PersonalLexiconCorrectionRecord]
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon)
        .font(.caption.bold())
        .foregroundStyle(color)

      ForEach(records) { record in
        correctionsRow(record: record, color: color)
      }
    }
  }

  private func correctionsRow(record: PersonalLexiconCorrectionRecord, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)
        Text("\(record.alias) -> \(record.canonical) (\(record.occurrences)x)")
        Spacer(minLength: 0)
        Text(record.confidence.rawValue.capitalized)
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
      .font(.caption)

      if let reason = record.reason, !reason.isEmpty {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var modelsSummary: String? {
    guard !item.modelsUsed.isEmpty else { return nil }
    let friendly = item.modelsUsed.map { ModelCatalog.friendlyName(for: $0) }
    return friendly.joined(separator: "\n")
  }

  private func metaTile<Content: View>(
    icon: String,
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: icon)
          .imageScale(.small)
          .foregroundStyle(Color.brandAccent.opacity(0.8))
        Text(title.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      content()
        .font(.footnote)
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.brandAccent.opacity(0.1), lineWidth: 1)
    )
  }
}
