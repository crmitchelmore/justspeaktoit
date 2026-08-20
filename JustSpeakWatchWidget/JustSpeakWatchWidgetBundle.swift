import SwiftUI
import WidgetKit

/// watchOS widget extension: the watch-face complication and the Smart Stack
/// entry. Both read the state the watch app publishes into the shared App
/// Group container and both start a recording through
/// `StartWatchRecordingIntent`.
@main
struct JustSpeakWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchRecordingComplication()
        WatchCaptureStatusWidget()
    }
}
