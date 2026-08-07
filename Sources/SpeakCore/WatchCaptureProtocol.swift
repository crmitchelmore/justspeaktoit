import Foundation

// MARK: - Watch Capture Protocol
//
// Shared wire types for Apple Watch → iPhone audio capture hand-off over
// WatchConnectivity. Pure Foundation so the same file compiles in SpeakCore
// (mac/iOS) and is included by direct source reference in the watchOS app
// target, which cannot depend on the package graph (several transitive
// package manifests do not declare watchOS support).
//
// Wire format: the envelope travels as a JSON string inside the
// `WCSessionFileTransfer` metadata dictionary; the acknowledgement travels
// back as a JSON string inside a `transferUserInfo` dictionary. Both sides
// tolerate unknown keys so the schema can grow.

/// Metadata describing one audio capture recorded on the watch, attached to
/// the WatchConnectivity file transfer that delivers the audio to the iPhone.
public struct WatchCaptureEnvelope: Codable, Equatable, Sendable {
    /// Bump when making incompatible changes to the payload.
    public static let currentSchemaVersion = 1

    /// Dictionary key under which the JSON-encoded envelope is stored in
    /// `WCSessionFileTransfer.file.metadata`.
    public static let metadataKey = "watchCaptureEnvelope"

    public let schemaVersion: Int
    /// Stable identity for the capture; the acknowledgement echoes it back.
    public let id: UUID
    /// When recording started on the watch.
    public let createdAt: Date
    /// Recorded duration in seconds.
    public let duration: TimeInterval
    /// Audio container extension, e.g. "m4a".
    public let fileExtension: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        duration: TimeInterval,
        fileExtension: String = "m4a",
        schemaVersion: Int = WatchCaptureEnvelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.fileExtension = fileExtension
    }

    /// Property-list-safe metadata dictionary for a WCSession file transfer.
    public func metadata() -> [String: Any]? {
        guard let json = WatchCaptureCoding.encodeToJSONString(self) else { return nil }
        return [Self.metadataKey: json]
    }

    /// Decodes an envelope from file-transfer metadata. Returns nil when the
    /// metadata is missing, malformed, or from an incompatible future schema.
    public static func from(metadata: [String: Any]?) -> WatchCaptureEnvelope? {
        guard let json = metadata?[metadataKey] as? String,
              let envelope: WatchCaptureEnvelope = WatchCaptureCoding.decodeFromJSONString(json),
              envelope.schemaVersion <= currentSchemaVersion
        else { return nil }
        return envelope
    }
}

/// Lifecycle of a capture as tracked on the watch.
public enum WatchCaptureStatus: String, Codable, CaseIterable, Sendable {
    /// Audio saved locally on the watch, not yet handed to WatchConnectivity.
    case recorded
    /// Queued with WatchConnectivity (survives the phone being out of range).
    case transferring
    /// WatchConnectivity confirmed delivery to the iPhone; the local audio
    /// file can be deleted.
    case delivered
    /// The iPhone acknowledged a successful transcription into history.
    case transcribed
    /// The transfer or the iPhone-side transcription failed.
    case failed

    /// Whether the capture needs no further action.
    public var isTerminal: Bool {
        self == .transcribed
    }

    /// Legal state-machine transitions:
    /// recorded → transferring; transferring → delivered/failed;
    /// delivered → transcribed/failed; failed → transferring (retry).
    public func canTransition(to next: WatchCaptureStatus) -> Bool {
        switch self {
        case .recorded:
            return next == .transferring
        case .transferring:
            return next == .delivered || next == .failed
        case .delivered:
            return next == .transcribed || next == .failed
        case .failed:
            return next == .transferring
        case .transcribed:
            return false
        }
    }
}

/// iPhone → watch acknowledgement for one capture, sent via
/// `transferUserInfo` so it queues while the watch is unreachable.
public struct WatchCaptureAck: Codable, Equatable, Sendable {
    /// Dictionary key under which the JSON-encoded ack is stored in the
    /// `transferUserInfo` payload.
    public static let userInfoKey = "watchCaptureAck"

    public enum Outcome: String, Codable, Sendable {
        case transcribed
        case failed
    }

    public let schemaVersion: Int
    /// Identity of the capture being acknowledged (`WatchCaptureEnvelope.id`).
    public let id: UUID
    public let outcome: Outcome
    /// Human-readable failure reason, when `outcome == .failed`.
    public let message: String?

    public init(
        id: UUID,
        outcome: Outcome,
        message: String? = nil,
        schemaVersion: Int = WatchCaptureEnvelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.outcome = outcome
        self.message = message
    }

    /// Property-list-safe payload for `WCSession.transferUserInfo`.
    public func userInfo() -> [String: Any]? {
        guard let json = WatchCaptureCoding.encodeToJSONString(self) else { return nil }
        return [Self.userInfoKey: json]
    }

    /// Decodes an ack from a `transferUserInfo` payload. Returns nil when the
    /// payload is unrelated, malformed, or from an incompatible future schema.
    public static func from(userInfo: [String: Any]?) -> WatchCaptureAck? {
        guard let json = userInfo?[userInfoKey] as? String,
              let ack: WatchCaptureAck = WatchCaptureCoding.decodeFromJSONString(json),
              ack.schemaVersion <= WatchCaptureEnvelope.currentSchemaVersion
        else { return nil }
        return ack
    }
}

/// JSON round-tripping with a stable date strategy for the watch protocol.
enum WatchCaptureCoding {
    static func encodeToJSONString<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeFromJSONString<Value: Decodable>(_ json: String) -> Value? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }
}
