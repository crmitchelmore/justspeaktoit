import SpeakCore
import AppKit
import SwiftUI

/// The duration, cost, model and error badges in a History row's header.
struct HistoryItemBadges: View {
  @Environment(\.appVisualDensity) private var density
  let item: HistoryItem

  @ViewBuilder
  var body: some View {
    historyBadge(
      icon: "calendar",
      title: "Created",
      value: formattedCreatedAt
    )

    if item.source == .importedFile {
      historyBadge(
        icon: "tray.and.arrow.down",
        title: "Source",
        value: "Imported",
        tint: .brandLagoon
      )
    }

    if item.recordingDuration > 0 {
      historyBadge(
        icon: "waveform",
        title: "Audio",
        value: HistoryRowFormatting.formatDuration(item.recordingDuration)
      )
    }

    if let prompt = promptDuration {
      historyBadge(
        icon: "bolt.fill",
        title: "Prompt",
        value: HistoryRowFormatting.formatDuration(prompt),
        tint: .brandAccent
      )
    }

    if let cost = item.cost {
      historyBadge(
        icon: "creditcard",
        title: "Cost",
        value: HistoryRowFormatting.formatCurrency(cost.total, currency: cost.currency),
        tint: .green
      )
    }

    if let error = errorBadgeInfo {
      historyBadge(
        icon: "exclamationmark.triangle.fill",
        title: error.title,
        value: error.value,
        tint: .orange
      )
    }
  }

  private func historyBadge(
    icon: String,
    title: String,
    value: String,
    tint: Color = .accentColor
  ) -> some View {
    Group {
      if density.isCompact {
        HStack(spacing: 3) {
          Image(systemName: icon)
            .imageScale(.small)
          Text(value)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
      } else {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Image(systemName: icon)
              .imageScale(.medium)
            Text(title.uppercased())
              .font(.caption2.weight(.semibold))
          }
          .foregroundStyle(tint)

          Text(value)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(0.12))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(tint.opacity(0.2), lineWidth: 1)
        )
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(value)")
  }
  private var promptDuration: TimeInterval? {
    let start =
      item.phaseTimestamps.transcriptionStarted
      ?? item.phaseTimestamps.recordingEnded
      ?? item.phaseTimestamps.recordingStarted
    let end =
      item.phaseTimestamps.outputDelivered
      ?? item.phaseTimestamps.postProcessingEnded
      ?? item.phaseTimestamps.transcriptionEnded

    guard let start, let end else { return nil }

    let duration = end.timeIntervalSince(start)
    guard duration.isFinite, duration > 0 else { return nil }

    return duration
  }

  private var errorBadgeInfo: (title: String, value: String)? {
    guard !item.errors.isEmpty else { return nil }
    if item.errors.count == 1 {
      let phase = item.errors.first?.phase.rawValue.capitalized ?? "Issue"
      return (title: "Error", value: phase)
    }
    return (title: "Errors", value: "\(item.errors.count) issues")
  }

  private var formattedCreatedAt: String {
    item.createdAt.formatted(date: .abbreviated, time: .shortened)
  }
}
