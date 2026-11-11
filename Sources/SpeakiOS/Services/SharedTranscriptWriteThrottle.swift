import Foundation

/// Rate limit for App Group transcript writes during live capture.
///
/// App Group writes (plist + cfprefsd IPC) and word counting are O(n) per
/// partial, so both the foreground coordinator and the headless service write
/// at most about once a second, matching the Live Activity manager's own
/// update throttle. The complete transcript is committed once more at stop.
struct SharedTranscriptWriteThrottle {
    static let interval: TimeInterval = 1.0

    private var lastWriteAt: Date = .distantPast

    /// Whether a partial arriving at `now` may be written. Admitting claims the
    /// slot, so the next partial within `interval` is refused.
    mutating func admit(at now: Date) -> Bool {
        guard now.timeIntervalSince(lastWriteAt) >= Self.interval else { return false }
        lastWriteAt = now
        return true
    }

    /// Opens the slot again, so a new run's first partial is always written.
    mutating func reset() {
        lastWriteAt = .distantPast
    }
}
