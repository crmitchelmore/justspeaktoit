import SwiftUI

/// Selects the system recording intent where watchOS supports it and preserves
/// the foreground-opening watchOS 10 fallback.
struct WatchRecordingActionButton<Label: View>: View {
    let state: WatchComplicationState
    private let label: Label

    init(state: WatchComplicationState, @ViewBuilder label: () -> Label) {
        self.state = state
        self.label = label()
    }

    var body: some View {
        Group {
            if #available(watchOS 11.0, *) {
                Button(intent: StartWatchRecordingIntent()) {
                    self.label
                }
            } else {
                Button(intent: OpenWatchRecordingIntent()) {
                    self.label
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(self.state.recordingActionLabel))
        .accessibilityHint(Text(self.state.recordingActionHint))
    }
}
