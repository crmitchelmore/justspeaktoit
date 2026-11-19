import SpeakCore
import SwiftUI

// MARK: - Entry Row

struct PronunciationEntryRow: View {
    @Environment(\.appVisualDensity) private var density
    let entry: PronunciationEntry

    var body: some View {
        HStack(spacing: density.isCompact ? density.inlineSpacing : 12) {
            VStack(alignment: .leading, spacing: density.isCompact ? 2 : 4) {
                HStack(spacing: 8) {
                    Text(entry.word)
                        .font(density.isCompact ? .caption.weight(.semibold) : .headline)
                        .lineLimit(1)

                    if entry.isRegex {
                        Text("REGEX")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.orange.opacity(0.2))
                            )
                            .foregroundStyle(.orange)
                    }

                    if entry.caseSensitive {
                        Text("Aa")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.brandLagoon.opacity(0.2))
                            )
                            .foregroundStyle(Color.brandLagoon)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                    Text(entry.pronunciation)
                        .font(density.isCompact ? .caption2 : .subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(density.isCompact ? 1 : nil)
                }
            }

            Spacer()

            if let category = entry.category {
                Text(category)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                    )
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .padding(density.isCompact ? 7 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(density.isCompact ? 0.7 : 1),
            in: RoundedRectangle(cornerRadius: density.isCompact ? 8 : 10, style: .continuous)
        )
    }
}
