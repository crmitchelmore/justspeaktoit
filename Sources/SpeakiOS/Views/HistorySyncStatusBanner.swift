#if os(iOS)
import SpeakCore
import SpeakSync
import SwiftUI

struct SyncStatusBanner: View {
    @Environment(\.appVisualDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var syncEngine: HistorySyncEngine
    let syncedCount: Int
    let unsyncedCount: Int
    let totalCount: Int

    var body: some View {
        Group {
            if usesInlineDensityLayout {
                HStack(spacing: density.inlineSpacing) {
                    Image(systemName: syncIcon)
                        .foregroundStyle(syncIconColor)

                    Text(syncEngine.state.statusMessage)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(totalCount == 0 ? "0" : "\(syncedCount)/\(totalCount)")
                        .foregroundStyle(.secondary)

                    if syncEngine.state.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .font(.caption)
            } else {
                regularContent
            }
        }
        .padding(.vertical, usesInlineDensityLayout ? 0 : 4)
    }

    private var regularContent: some View {
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

    private var usesInlineDensityLayout: Bool {
        density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
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
