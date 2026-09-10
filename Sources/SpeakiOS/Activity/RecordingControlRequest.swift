import Foundation
import SpeakCore

/// A SetValueIntent requests a value; repeating that request must never invert it.
enum RecordingControlRequest {
    enum Action: Equatable {
        case start
        case stop
        case none
    }

    enum RequestError: LocalizedError {
        case alreadyRecordingInApp
        case recordingIsStopping

        var errorDescription: String? {
            switch self {
            case .alreadyRecordingInApp:
                return "A recording is already in progress in the app. Use the in-app stop button."
            case .recordingIsStopping:
                return "The recording is still stopping. Try again when it has finished."
            }
        }
    }

    static func action(
        desiredValue: Bool,
        serviceState: RecordingServiceState,
        sharedIsRecording: Bool
    ) throws -> Action {
        switch serviceState {
        case .starting, .recording:
            return desiredValue ? .none : .stop
        case .stopping:
            // Preserve the stop guard without claiming a new start succeeded.
            if desiredValue { throw RequestError.recordingIsStopping }
            return .none
        case .idle:
            // This service cannot stop the foreground owner's microphone, and
            // must not start a second recorder or report a successful stop.
            if sharedIsRecording { throw RequestError.alreadyRecordingInApp }
            return desiredValue ? .start : .none
        }
    }
}
