import SwiftUI
import WidgetKit

/// Watch-face complication: one tap starts a recording, the next stops it.
///
/// Circular and corner families — the two the watch face offers for a single
/// glyph-plus-state control.
struct WatchRecordingComplication: Widget {
    static let kind = "JustSpeakWatchRecordingComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchComplicationProvider()) { entry in
            WatchRecordingComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Record")
        .description("Start or stop a voice note from your watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

struct WatchRecordingComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchComplicationEntry

    var body: some View {
        WatchRecordingActionButton(state: entry.snapshot.state) {
            switch family {
            case .accessoryCorner:
                cornerContent
            default:
                circularContent
            }
        }
    }

    private var circularContent: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: entry.snapshot.state.symbolName)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(entry.snapshot.state.tint)
        }
    }

    /// The corner family draws a glyph in the corner with the state as its
    /// curved label along the bezel.
    private var cornerContent: some View {
        Image(systemName: entry.snapshot.state.symbolName)
            .font(.title3)
            .foregroundStyle(entry.snapshot.state.tint)
            .widgetLabel(entry.snapshot.state.shortLabel)
    }
}

extension WatchComplicationState {
    /// Watch faces tint complications themselves in most cases; these read
    /// through on the faces that keep full colour.
    var tint: Color {
        switch self {
        case .idle: return .accentColor
        case .recording: return .red
        case .sending: return .blue
        case .inHistory: return .green
        case .failed: return .orange
        }
    }
}
