import SpeakCore
import SwiftUI

/// Live preview of the saved rules against sample text, using the draft's context tags.
struct PersonalCorrectionsPreviewSection: View {
  @EnvironmentObject private var lexicon: PersonalLexiconService
  @Environment(\.appVisualDensity) private var density
  @State private var previewText: String = "Hey love, Susie and I will join the meeting at 3pm."
  let previewTags: Set<String>

  var body: some View {
    let context = PersonalLexiconContext(
      tags: previewTags,
      destinationApplication: "Preview",
      recentTranscriptWindow: previewText
    )
    let preview = lexicon.apply(to: previewText, context: context)

    return SpeakDensityCard(title: "Preview", systemImage: "eye", tint: .brandLagoon) {
      TextEditor(text: $previewText)
        .accessibilityLabel("Preview text")
        .frame(minHeight: density.isCompact ? 64 : 120)
        .padding(density.isCompact ? 5 : 12)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
        )
      VStack(alignment: .leading, spacing: density.inlineSpacing) {
        Text("Transformed")
          .font(.caption.bold())
        Text(preview.transformedText)
          .padding(density.isCompact ? 5 : 12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .fill(Color(nsColor: .underPageBackgroundColor))
          )
      }

      recordList("Applied corrections", records: preview.applied)
      recordList("Suggestions", records: preview.suggestions)
    }
  }

  @ViewBuilder
  private func recordList(_ title: String, records: [PersonalLexiconCorrectionRecord]) -> some View {
    if !records.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.caption.bold())
        ForEach(records, id: \.id) { record in
          correctionRow(record)
        }
      }
    }
  }

  private func correctionRow(_ record: PersonalLexiconCorrectionRecord) -> some View {
    HStack(spacing: 8) {
      Image(systemName: record.wasApplied ? "wand.and.stars" : "questionmark.circle")
        .foregroundStyle(record.wasApplied ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(record.alias) -> \(record.canonical) (\(record.occurrences)x)")
          .font(.caption)
        if let reason = record.reason {
          Text(reason)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(PersonalCorrectionLabels.label(for: record.confidence))
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
  }
}
