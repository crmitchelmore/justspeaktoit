#if os(iOS)
import Foundation
import SpeakCore
import WidgetKit

/// Pushes the recording state out to the surfaces that render it from the App
/// Group but are not observing it.
///
/// WidgetKit and Control Center only re-read their providers when the system
/// decides to, or when the app asks. The Transcribe widget's timeline uses
/// `.never` (its elapsed time is a `Text(timerInterval:)`, so it needs no
/// scheduled entries) and the Control's `currentValue` is only queried on
/// demand, so without this call both go stale as soon as a recording starts or
/// stops from any other surface — showing "Dictate" during a live recording, or
/// "Recording" long after one ended.
///
/// Called from `SharedTranscriptionState.isRecording`, which every entry point
/// already writes, so there is one choke point rather than a call per caller.
@MainActor
public enum CaptureSurfaceRefresher {
    /// Reloads the Transcribe widget and the Control Center control.
    ///
    /// Cheap and infrequent: `isRecording` changes a handful of times per
    /// session (start, stop, cancel, unwind), not per partial result.
    public static func recordingStateChanged() {
        WidgetCenter.shared.reloadTimelines(ofKind: CaptureSurfaceKind.transcribeWidget)
        if #available(iOS 18, *) {
            ControlCenter.shared.reloadControls(ofKind: CaptureSurfaceKind.transcriptionControl)
        }
    }
}

/// Widget and control kind strings, shared between the app and the widget
/// extension so a rename cannot silently orphan a placed widget or control.
public enum CaptureSurfaceKind {
    public static let transcribeWidget = "TranscribeWidget"
    public static let transcriptionControl = "com.justspeaktoit.ios.JustSpeakToItWidgetExtension"
}
#endif
