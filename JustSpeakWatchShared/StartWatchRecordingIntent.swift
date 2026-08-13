import AppIntents
import Foundation

/// Starts (or stops) a watch recording from the watch face on watchOS 11+.
///
/// Compiled into both watchOS targets — the widget extension needs the type to
/// build the complication's button, the app needs it to actually record — so
/// the body is split by `WATCH_WIDGET_EXTENSION`:
///
/// `AudioRecordingIntent` tells watchOS to run the action in the app process
/// without presenting its foreground UI and to provide the system recording
/// indicator for the lifetime of the active audio session. ActivityKit itself
/// is unavailable to watchOS apps; this system surface is the watchOS recording
/// equivalent of the Live Activity required on ActivityKit platforms.
@available(watchOS 11.0, *)
struct StartWatchRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource { "Record Voice Note" }

    static var description: IntentDescription {
        IntentDescription("Starts a recording on the watch, or stops the one in progress.")
    }

    static var openAppWhenRun: Bool { false }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WATCH_WIDGET_EXTENSION
        // AudioRecordingIntent is performed by the containing app process.
        // The extension copy exists so WidgetKit can archive the button.
        #else
        await WatchRecordingCoordinator.shared.toggleRecording()
        #endif
        return .result()
    }
}

/// watchOS 10 fallback. That OS predates `AudioRecordingIntent`, so opening the
/// app is the only supported way to establish its microphone session.
struct OpenWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource { "Record Voice Note" }

    static var description: IntentDescription {
        IntentDescription("Opens Just Speak to It to start or stop a watch recording.")
    }

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
