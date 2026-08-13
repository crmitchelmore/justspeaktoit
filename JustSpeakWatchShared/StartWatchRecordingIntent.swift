import AppIntents
import Foundation

/// Starts (or stops) a watch recording from the watch face.
///
/// Compiled into both watchOS targets — the widget extension needs the type to
/// build the complication's button, the app needs it to actually record — so
/// the body is split by `WATCH_WIDGET_EXTENSION`:
///
/// - In the app process (already running, e.g. the complication was tapped
///   while the app was in the background) the intent toggles
///   `WatchAudioRecorder.toggle(store:)` directly, with no UI launch.
/// - In the widget process the microphone and audio session are unavailable,
///   so the intent leaves a `WatchRecordingRequest` in the shared container
///   and `openAppWhenRun` hands over to the app, which performs it on
///   activation.
struct StartWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource { "Record Voice Note" }

    static var description: IntentDescription {
        IntentDescription("Starts a recording on the watch, or stops the one in progress.")
    }

    /// watchOS cannot capture audio from a widget extension process, so the
    /// app has to come forward. When the intent is already running in the app
    /// this costs nothing beyond the app it is running in.
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WATCH_WIDGET_EXTENSION
        WatchRecordingRequest().post()
        #else
        await WatchRecordingCoordinator.shared.toggleRecording()
        #endif
        return .result()
    }
}
