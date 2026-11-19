import SwiftUI

/// Renders one release note with native text styles.
///
/// Shared by the macOS and iOS release-note screens so both platforms present
/// identical content, inherit Dynamic Type and expose headings to VoiceOver.
public struct ReleaseNotesContentView: View {
    private let entry: ReleaseNoteEntry
    private let showsVersionHeader: Bool
    @ScaledMetric(relativeTo: .body) private var bulletIndent: CGFloat = 16

    public init(entry: ReleaseNoteEntry, showsVersionHeader: Bool = true) {
        self.entry = entry
        self.showsVersionHeader = showsVersionHeader
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsVersionHeader {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(entry.version)")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if let published = entry.publishedDate {
                        Text(published.formatted(date: .long, time: .omitted))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)
            }

            ForEach(entry.blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNoteBlock) -> some View {
        switch block.kind {
        case .heading:
            Text(block.attributedText)
                .font(.headline)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
        case .subheading:
            Text(block.attributedText)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            Text(block.attributedText)
                .font(.body)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(block.attributedText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(block.indentLevel) * bulletIndent)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(block.plainText)
        }
    }
}
