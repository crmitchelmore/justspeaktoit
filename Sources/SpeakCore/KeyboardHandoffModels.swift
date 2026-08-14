import Foundation

/// The only App Group payload used by the custom keyboard handoff.
///
/// Audio, API keys, and surrounding text are never written here. A throttled
/// interim transcript lets the keyboard show live feedback; the final copy
/// exists only until the matching keyboard consumes it or the short result
/// timeout expires. History persistence happens separately inside the app.
public struct KeyboardHandoffRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 3

    public enum Phase: String, Codable, Equatable, Hashable, Sendable {
        case requested
        case recording
        case finishRequested
        case transcribing
        case completed
        case cancelled
        case failed
    }

    public enum FailureCode: String, Codable, Equatable, Sendable {
        case fullAccessRequired
        case appUnavailable
        case recordingUnavailable
        case noSpeech
        case timedOut
        case invalidRequest
        case targetChanged
        case profileUnavailable
        case unknown
    }

    public let schemaVersion: Int
    public let requestID: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let expiresAt: Date
    public let phase: Phase
    public let targetDocumentIdentifier: UUID?
    /// Immutable capability snapshot selected before recording began.
    public let profile: KeyboardDictationProfileOption?
    public let interimTranscript: String?
    public let transcript: String?
    public let failureCode: FailureCode?

    public init(
        schemaVersion: Int = Self.schemaVersion,
        requestID: UUID,
        createdAt: Date,
        updatedAt: Date,
        expiresAt: Date,
        phase: Phase,
        targetDocumentIdentifier: UUID? = nil,
        profile: KeyboardDictationProfileOption? = nil,
        interimTranscript: String? = nil,
        transcript: String? = nil,
        failureCode: FailureCode? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.phase = phase
        self.targetDocumentIdentifier = targetDocumentIdentifier
        self.profile = profile
        self.interimTranscript = interimTranscript
        self.transcript = transcript
        self.failureCode = failureCode
    }
}

public struct KeyboardExtensionObservation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let lastSeenAt: Date
    public let hadFullAccess: Bool

    public init(
        schemaVersion: Int = KeyboardHandoffRecord.schemaVersion,
        lastSeenAt: Date,
        hadFullAccess: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.lastSeenAt = lastSeenAt
        self.hadFullAccess = hadFullAccess
    }
}

public enum KeyboardHandoffStoreError: Error, Equatable {
    case unavailable
    case noActiveRequest
    case mismatchedRequest
    case invalidTransition
    case invalidTranscript
}
