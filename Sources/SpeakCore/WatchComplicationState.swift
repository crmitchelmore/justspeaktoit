import Foundation

// MARK: - Watch Complication State
//
// What the watch face shows, and how the complication asks for a recording.
// Pure Foundation (no WidgetKit, no SwiftUI) so the same file compiles in
// SpeakCore and is included by direct source reference in both watchOS
// targets: the app writes these payloads, the widget extension reads them.

/// The single piece of state a watch face shows for Just Speak to It.
public enum WatchComplicationState: String, Codable, CaseIterable, Sendable {
    /// Nothing recording and nothing in flight.
    case idle
    /// A capture is being recorded right now.
    case recording
    /// A capture is on its way to (or being transcribed on) the iPhone.
    case sending
    /// The most recent capture reached iPhone history.
    case inHistory
    /// The most recent capture failed to transfer or transcribe.
    case failed

    /// Derives the face state from the recorder plus the newest capture.
    /// Recording always wins: it is the state the user is acting on.
    public static func state(
        isRecording: Bool,
        latestCaptureStatus: WatchCaptureStatus?
    ) -> WatchComplicationState {
        if isRecording { return .recording }
        switch latestCaptureStatus {
        case .none: return .idle
        case .recorded, .transferring, .delivered: return .sending
        case .transcribed: return .inHistory
        case .failed: return .failed
        }
    }

    /// SF Symbol shown in the circular/corner complication.
    public var symbolName: String {
        switch self {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .sending: return "arrow.up.circle.fill"
        case .inHistory: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Corner/inline text — must stay very short to survive the watch face.
    public var shortLabel: String {
        switch self {
        case .idle: return "Speak"
        case .recording: return "Rec"
        case .sending: return "Sending"
        case .inHistory: return "Done"
        case .failed: return "Failed"
        }
    }

    /// Smart Stack (rectangular) headline.
    public var label: String {
        switch self {
        case .idle: return "Tap to record"
        case .recording: return "Recording…"
        case .sending: return "Sending to iPhone…"
        case .inHistory: return "In history"
        case .failed: return "Capture failed"
        }
    }

    /// VoiceOver action name for the complication and Smart Stack button.
    public var recordingActionLabel: String {
        self == .recording ? "Stop recording" : "Start recording"
    }

    /// State-aware context without making the icon's SF Symbol name the
    /// accessible name of the command.
    public var recordingActionHint: String {
        switch self {
        case .recording:
            return "Stops and sends this voice note to your iPhone."
        case .idle:
            return "Records a new voice note on your Apple Watch."
        case .sending:
            return "Starts another voice note while the previous capture is in progress."
        case .inHistory:
            return "Starts another voice note after the latest capture reached history."
        case .failed:
            return "Starts another voice note after the latest capture failed."
        }
    }

    /// Smart Stack relevance: an in-flight capture is worth surfacing on the
    /// wrist, a long-settled idle complication is not.
    public var relevanceScore: Float {
        switch self {
        case .recording: return 100
        case .sending: return 75
        case .failed: return 60
        case .inHistory: return 40
        case .idle: return 0
        }
    }

    /// How long the state stays relevant in the Smart Stack.
    public var relevanceDuration: TimeInterval {
        switch self {
        case .recording, .sending: return 15 * 60
        case .failed, .inHistory: return 30 * 60
        case .idle: return 0
        }
    }
}

/// What the watch app publishes into the App Group container for the widget
/// extension to render. Deliberately narrow: the complication never needs the
/// capture queue itself, only the state it should show.
public struct WatchComplicationSnapshot: Codable, Equatable, Sendable {
    /// Bump when making incompatible changes to the payload.
    public static let currentSchemaVersion = 1

    /// File name inside the shared container.
    public static let fileName = "watch-complication.json"

    /// The app writes the snapshot again at this interval while it records.
    /// The refreshed `updatedAt` shows that the recording continues.
    public static let recordingHeartbeat: TimeInterval = 30

    /// A `recording` snapshot older than this is not believable. Only a
    /// stopped app can leave one, because a live recording sends a heartbeat
    /// every `recordingHeartbeat` seconds.
    public static let recordingStaleAfter: TimeInterval = 5 * 60

    /// What a face shows before the app has ever published anything.
    public static let idle = WatchComplicationSnapshot(
        state: .idle,
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    public let schemaVersion: Int
    public let state: WatchComplicationState
    /// When the app last published this state.
    public let updatedAt: Date
    /// Start of the active recording, when `state == .recording`.
    public let recordingStartedAt: Date?
    /// Start time of the newest capture, for the Smart Stack subtitle.
    public let latestCaptureAt: Date?
    /// Unprojected newest queue state, retained for diagnostics and migration.
    public let latestCaptureStatus: WatchCaptureStatus?
    /// Latest user-facing failure reason, when the newest capture failed.
    public let failureMessage: String?
    /// Explicit recording expiry refreshed by the app heartbeat.
    public let expiresAt: Date?
    /// Captures that are recorded but not yet in history. Counts every status
    /// the face calls "sending", so the headline and the subtitle agree.
    public let inFlightCount: Int

    public init(
        state: WatchComplicationState,
        updatedAt: Date = Date(),
        recordingStartedAt: Date? = nil,
        latestCaptureAt: Date? = nil,
        latestCaptureStatus: WatchCaptureStatus? = nil,
        failureMessage: String? = nil,
        expiresAt: Date? = nil,
        inFlightCount: Int = 0,
        schemaVersion: Int = WatchComplicationSnapshot.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.updatedAt = updatedAt
        self.recordingStartedAt = recordingStartedAt
        self.latestCaptureAt = latestCaptureAt
        self.latestCaptureStatus = latestCaptureStatus
        self.failureMessage = failureMessage
        self.expiresAt = expiresAt
        self.inFlightCount = inFlightCount
    }

    /// Clears a `recording` state that the app never got to replace. If the
    /// app stops during a recording, the file keeps `recording` and no process
    /// writes it again, so a face must not show that state forever.
    public func settled(now: Date = Date()) -> WatchComplicationSnapshot {
        guard self.state == .recording else { return self }
        let expiry = self.expiresAt ?? self.updatedAt.addingTimeInterval(Self.recordingStaleAfter)
        guard now > expiry else { return self }
        return WatchComplicationSnapshot(
            state: .idle,
            updatedAt: self.updatedAt,
            recordingStartedAt: nil,
            latestCaptureAt: self.latestCaptureAt,
            latestCaptureStatus: self.latestCaptureStatus,
            failureMessage: self.failureMessage,
            expiresAt: nil,
            inFlightCount: self.inFlightCount,
            schemaVersion: self.schemaVersion
        )
    }

    public func encoded() -> Data? {
        WatchCaptureCoding.encode(self)
    }

    /// Decodes a published snapshot, rejecting an incompatible future schema
    /// so a downgraded widget shows idle rather than wrong state.
    public static func decode(from data: Data) -> WatchComplicationSnapshot? {
        guard let snapshot: WatchComplicationSnapshot = WatchCaptureCoding.decode(from: data),
              snapshot.schemaVersion <= currentSchemaVersion
        else { return nil }
        return snapshot
    }

    /// Publishes the snapshot where the widget extension can read it.
    public func save(in container: WatchSharedContainer = .shared) {
        guard let data = self.encoded() else { return }
        container.write(data, named: Self.fileName)
    }

    /// Latest published state, or `.idle` when nothing readable is there.
    public static func load(from container: WatchSharedContainer = .shared) -> WatchComplicationSnapshot {
        guard let data = container.read(named: fileName),
              let snapshot = decode(from: data)
        else { return idle }
        return snapshot
    }
}

/// A record/stop request left by the complication's App Intent for the watch
/// app to pick up.
///
/// Recording needs the microphone and an active audio session, which a widget
/// extension process cannot own, so the intent opens the app; when the intent
/// happens to run in the widget process the request file is what carries the
/// tap across. Stale requests are ignored so a queued tap cannot start a
/// recording minutes later.
public struct WatchRecordingRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let fileName = "watch-recording-request.json"

    /// A request older than this is discarded unperformed.
    public static let freshnessWindow: TimeInterval = 30

    public let schemaVersion: Int
    /// Identity so the app can tell a re-read of the same tap from a new one.
    public let id: UUID
    public let requestedAt: Date

    public init(
        id: UUID = UUID(),
        requestedAt: Date = Date(),
        schemaVersion: Int = WatchRecordingRequest.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.requestedAt = requestedAt
    }

    /// Whether the request is recent enough to still act on.
    public func isFresh(now: Date = Date(), window: TimeInterval = WatchRecordingRequest.freshnessWindow) -> Bool {
        let age = now.timeIntervalSince(self.requestedAt)
        return age >= -window && age <= window
    }

    public func encoded() -> Data? {
        WatchCaptureCoding.encode(self)
    }

    public static func decode(from data: Data) -> WatchRecordingRequest? {
        guard let request: WatchRecordingRequest = WatchCaptureCoding.decode(from: data),
              request.schemaVersion <= currentSchemaVersion
        else { return nil }
        return request
    }

    /// Leaves the request for the watch app.
    public func post(in container: WatchSharedContainer = .shared) {
        guard let data = self.encoded() else { return }
        container.write(data, named: Self.fileName)
    }

    /// Takes the pending request, removing it so it is performed at most once.
    /// Returns nil when there is none or it has gone stale.
    public static func consume(
        now: Date = Date(),
        from container: WatchSharedContainer = .shared
    ) -> WatchRecordingRequest? {
        guard let data = container.read(named: fileName) else { return nil }
        container.remove(named: fileName)
        guard let request = decode(from: data), request.isFresh(now: now) else { return nil }
        return request
    }
}
