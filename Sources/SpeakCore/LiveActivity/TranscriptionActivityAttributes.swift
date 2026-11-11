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
