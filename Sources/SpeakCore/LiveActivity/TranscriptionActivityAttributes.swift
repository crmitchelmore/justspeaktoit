import Foundation

#if os(iOS)
import ActivityKit
#endif

/// ActivityKit attributes for live transcription sessions.
/// Defines the static and dynamic content shown in Live Activities and Dynamic Island.
public struct TranscriptionActivityAttributes {

    /// Transcription session status
    public enum TranscriptionStatus: String, Codable, Hashable {
        case idle
        case arming
        case armed
        case recording
        case finalising
        case listening
        case processing
        case paused
        case error
        case completed

        /// Whether the Live Activity offers Stop, and with it the Watch Smart
        /// Stack's Double Tap primary action (issue #963). Only live capture is
        /// stoppable; every other state must never expose a gesture that could
        /// be mistaken for Start. The switch is exhaustive so a new status has
        /// to decide explicitly.
        public var offersStopAction: Bool {
            switch self {
            case .recording, .listening:
                true
            case .idle, .arming, .armed, .finalising, .processing, .paused, .error, .completed:
                false
            }
        }
    }

    /// Session identifier
    public var sessionId: String
    /// Start time of the session
    public var startTime: Date

    public init(sessionId: String = UUID().uuidString, startTime: Date = Date()) {
        self.sessionId = sessionId
        self.startTime = startTime
    }
}

#if os(iOS)
extension TranscriptionActivityAttributes: ActivityAttributes {}
#endif
