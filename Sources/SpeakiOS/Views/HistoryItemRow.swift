#if os(iOS)
import SwiftUI
import SpeakSync

// MARK: - History Item Row

struct HistoryItemRow: View {
    let item: iOSHistoryItem
    let isSynced: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

                HStack(spacing: 8) {
                    Image(
                        systemName: isSynced ? "icloud.fill" : "icloud.slash"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        isSynced ? .green : .secondary.opacity(0.5)
                    )

                    Label(
                        "\(item.wordCount)",
                        systemImage: "text.word.spacing"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(formatDuration(item.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(item.transcription)
                .font(.body)
                .lineLimit(isExpanded ? nil : 3)
                .animation(.easeInOut(duration: 0.2), value: isExpanded)

            HStack {
                Text(modelDisplayName)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color.secondary.opacity(0.15),
                        in: Capsule()
                    )

                if item.originPlatform != "ios" {
                    Text(platformDisplayName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Color.blue.opacity(0.15),
                            in: Capsule()
                        )
                }

                Spacer()

                if item.transcription.count > 150 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.transcription.count > 150 {
                isExpanded.toggle()
            }
        }
    }

    private var modelDisplayName: String {
        if item.model.contains("deepgram") {
            return "Deepgram"
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

// MARK: - Sync Status Banner

struct SyncStatusBanner: View {
    @ObservedObject var syncEngine: HistorySyncEngine
    let syncedCount: Int
    let unsyncedCount: Int
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: syncIcon)
                    .foregroundStyle(syncIconColor)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text(syncEngine.state.statusMessage)
                        .font(.subheadline.weight(.medium))
                    Text(syncSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if syncEngine.state.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if totalCount > 0 {
                syncProgressBar
            }

            if let error = syncEngine.state.error {
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var syncProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 4)
                Capsule()
                    .fill(syncBarColor)
                    .frame(
                        width: geometry.size.width * syncFraction,
                        height: 4
                    )
            }
        }
        .frame(height: 4)
    }

    private var syncFraction: CGFloat {
        guard totalCount > 0 else { return 0 }
        return CGFloat(syncedCount) / CGFloat(totalCount)
    }

    private var syncSummary: String {
        if totalCount == 0 {
            return "No entries"
        }
        if unsyncedCount == 0 {
            return "All \(totalCount) entries synced"
        }
        return "\(syncedCount)/\(totalCount) synced · \(unsyncedCount) pending"
    }

    private var syncIcon: String {
        if syncEngine.state.isSyncing {
            return "arrow.triangle.2.circlepath.icloud"
        }
        if syncEngine.state.error != nil {
            return "exclamationmark.icloud"
        }
        if unsyncedCount == 0, totalCount > 0 {
            return "checkmark.icloud.fill"
        }
        return "icloud.fill"
    }

    private var syncIconColor: Color {
        if syncEngine.state.error != nil {
            return .orange
        }
        if unsyncedCount == 0, totalCount > 0 {
            return .green
        }
        return .blue
    }

    private var syncBarColor: Color {
        if syncEngine.state.error != nil {
            return .orange
        }
        return .green
    }
}
#endif
