// When the launch prompt offers interrupted audio back (issues #992, #1617).
//
// The scanner decides what a claim *is*; this decides whether the user is
// *asked* about it. Answering "Not now" is a decision too: the same recording
// must not come back on every launch. It returns only when a newer
// interruption happens, while every recoverable capture stays listed in
// Capture Health for a deliberate retry.
import Foundation

public enum CaptureRecoveryPromptPolicy {
    /// The recoverable captures the launch prompt may offer, oldest first:
    /// those that started after everything the user already put off.
    public static func promptable(
        _ recoverable: [CaptureRecoveryFinding],
        snoozedThrough: Date?
    ) -> [CaptureRecoveryFinding] {
        let offered = recoverable
            .filter { $0.disposition == .recoverable }
            .sorted { $0.startedAt < $1.startedAt }
        guard let snoozedThrough else { return offered }
        return offered.filter { $0.startedAt > snoozedThrough }
    }

    /// The watermark after "Not now": the newest start among the captures the
    /// user just put off. It never moves backwards, so a stale answer cannot
    /// revive a recording that was already put off.
    public static func snoozedThrough(
        after putOff: [CaptureRecoveryFinding],
        current: Date?
    ) -> Date? {
        let newest = putOff.map(\.startedAt).max()
        switch (current, newest) {
        case let (current?, newest?): return max(current, newest)
        case let (current, nil): return current
        case let (nil, newest): return newest
        }
    }
}
