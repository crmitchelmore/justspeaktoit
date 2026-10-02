import Foundation

/// What the native History pane shows for one record: the acknowledged state
/// and the elapsed/remaining text. Record-bound so a stale update can never
/// describe another row.
public struct WindowsAudioPlaybackDisplay: Equatable, Sendable {
    public enum State: Int32, Equatable, Sendable {
        case idle = 0
        case preparing = 1
        case playing = 2
        case paused = 3
    }

    public let revision: UInt64
    public let recordID: UUID
    public let state: State
    public let text: String

    public init(recordID: UUID, state: State, text: String, revision: UInt64 = 0) {
        self.revision = revision
        self.recordID = recordID
        self.state = state
        self.text = text
    }

    /// "elapsed / remaining" in the Apple History format. An unknown duration
    /// is shown honestly as "--:--" rather than a guessed remainder.
    public static func text(position: TimeInterval, duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "\(format(position)) / --:--" }
        return "\(format(position)) / \(format(max(duration - position, 0)))"
    }

    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0, time < Double(Int64.max / 100) else { return "--:--.--" }
        let hundredths = Int64((time * 100).rounded())
        return String(format: "%02lld:%02lld.%02lld", hundredths / 6_000, (hundredths / 100) % 60, hundredths % 100)
    }
}

/// A revision accompanies status messages because a host may forward them to
/// an actor after the native display has already moved to a different run.
public struct WindowsAudioPlaybackStatus: Sendable {
    public let revision: UInt64
    public let message: String
}

public struct WindowsAudioPlaybackPresenter: Sendable {
    public let show: @Sendable (WindowsAudioPlaybackDisplay) -> Void
    public let status: @Sendable (WindowsAudioPlaybackStatus) -> Void

    public init(
        show: @escaping @Sendable (WindowsAudioPlaybackDisplay) -> Void,
        status: @escaping @Sendable (WindowsAudioPlaybackStatus) -> Void
    ) {
        self.show = show
        self.status = status
    }
}
