#if os(iOS)
import SwiftUI
import SpeakCore
import SpeakSync

// MARK: - History Item Row

struct HistoryItemRow: View {
    @Environment(\.appVisualDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: iOSHistoryItem
    let isSynced: Bool
    var isReprocessing: Bool = false
    var onCopyRaw: () -> Void = {}
    var onCopyPolished: () -> Void = {}
    var onReprocess: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.isCompact ? density.cardContentSpacing : 8) {
            metadataHeader

            transcriptSection(title: "Original", text: item.transcription)

            if isReprocessing {
                Label("Polishing… please wait", systemImage: "wand.and.stars")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let polished = item.postProcessedTranscription, !polished.isEmpty {
                transcriptSection(title: "Polished", text: polished)
            }

            if let error = item.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(isExpanded ? nil : 2)
            }

            metadataFooter
        }
        .padding(.vertical, density.listRowVerticalPadding)
        .frame(minHeight: density.minimumListRowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if max(item.transcription.count, item.postProcessedTranscription?.count ?? 0) > 150 {
                isExpanded.toggle()
            }
        }
        .contextMenu {
            Button {
                onCopyRaw()
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }

            if item.hasPolishedText {
                Button {
                    onCopyPolished()
                } label: {
                    Label("Copy Polished", systemImage: "doc.on.doc.fill")
                }
            }

            Button {
                onReprocess()
            } label: {
                Label("Reprocess", systemImage: "wand.and.stars")
            }
            .disabled(isReprocessing)

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var metadataHeader: some View {
        if usesInlineDensityLayout {
            HStack(spacing: density.inlineSpacing) {
                Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)
                sessionMetrics
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
                sessionMetrics
            }
        }
    }

    private var sessionMetrics: some View {
        HStack(spacing: density.isCompact ? density.inlineSpacing : 8) {
            if isReprocessing {
                ProgressView()
                    .controlSize(.small)
            }

            Image(systemName: isSynced ? "icloud.fill" : "icloud.slash")
                .font(.caption2)
                .foregroundStyle(isSynced ? .green : .secondary.opacity(0.5))
                .accessibilityLabel(isSynced ? "Synced" : "Not synced")

            Label("\(item.wordCount)", systemImage: "text.word.spacing")
                .accessibilityLabel("\(item.wordCount) words")

            Text(formatDuration(item.duration))
        }
        .font(density.isCompact ? .caption2 : .caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var metadataFooter: some View {
        if usesInlineDensityLayout {
            HStack(spacing: density.inlineSpacing) {
                Label(modelDisplayName, systemImage: "waveform")
                    .lineLimit(1)

                if item.hasPolishedText {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.purple)
                        .accessibilityLabel("Polished")
                }

                if item.originPlatform != "ios" {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.blue)
                        .accessibilityLabel(platformDisplayName)
                }

                Spacer(minLength: 4)

                if canExpand {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(isExpanded ? "Show less" : "Show more")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            HStack {
                Text(modelDisplayName)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15), in: Capsule())

                if item.hasPolishedText {
                    Label("Polished", systemImage: "wand.and.stars")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                }

                if item.originPlatform != "ios" {
                    Text(platformDisplayName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                }

                Spacer()

                if canExpand {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(title: String, text: String) -> some View {
        if usesInlineDensityLayout {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if title == "Polished" {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.purple)
                        .accessibilityLabel(title)
                }
                Text(text)
                    .font(.subheadline)
                    .lineLimit(isExpanded ? nil : 1)
            }
            .animation(.easeInOut(duration: 0.2), value: isExpanded)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.body)
                    .lineLimit(isExpanded ? nil : 3)
            }
            .animation(.easeInOut(duration: 0.2), value: isExpanded)
        }
    }

    private var usesInlineDensityLayout: Bool {
        density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
    }

    private var canExpand: Bool {
        max(item.transcription.count, item.postProcessedTranscription?.count ?? 0) > 150
    }

    private var modelDisplayName: String {
        if item.model.contains("deepgram") {
            return "Deepgram"
        } else if item.model.contains("elevenlabs") {
            return "ElevenLabs"
        } else if item.model.contains("apple") {
            return "Apple Speech"
        }
        return item.model
    }

    private var platformDisplayName: String {
        switch item.originPlatform {
        case "macos":
            return "Mac"
        case "ios":
            return "iPhone"
        default:
            return item.originPlatform
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}

#endif
