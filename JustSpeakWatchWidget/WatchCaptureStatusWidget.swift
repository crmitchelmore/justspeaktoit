import SwiftUI
import WidgetKit

/// Smart Stack entry: what happened to the most recent capture, and a tap
/// target to start the next one.
///
/// Relevance comes from the entry (see `WatchComplicationProvider`), so the
/// stack surfaces the widget while a capture is recording or in flight and
/// lets it sink once everything has settled.
struct WatchCaptureStatusWidget: Widget {
    static let kind = "JustSpeakWatchCaptureStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchComplicationProvider()) { entry in
            WatchCaptureStatusView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Just Speak to It")
        .description("Status of your latest watch capture, and a tap to record another.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct WatchCaptureStatusView: View {
    let entry: WatchComplicationEntry

    var body: some View {
        WatchRecordingActionButton(state: entry.snapshot.state) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: entry.snapshot.state.symbolName)
                        .foregroundStyle(entry.snapshot.state.tint)
                    Text("Just Speak to It")
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(entry.snapshot.state.label)
                    .font(.caption)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// Second line: how many captures are still on their way, or when the last
    /// one was taken. Nothing at all before the first capture.
    private var detail: String? {
        if entry.snapshot.inFlightCount > 1 {
            return "\(entry.snapshot.inFlightCount) captures in progress"
        }
        guard let latest = entry.snapshot.latestCaptureAt else { return nil }
        return latest.formatted(.relative(presentation: .numeric))
    }
}
