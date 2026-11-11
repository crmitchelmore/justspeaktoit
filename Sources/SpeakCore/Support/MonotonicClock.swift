import Foundation

/// Elapsed time that cannot be moved by the wall clock.
///
/// Every bound this app puts on a capture exists for a safety reason — a
/// maximum recording duration so a failed silence detector cannot leave the
/// microphone open, an intent budget so the system does not kill a Shortcut
/// with no result. `Date` is the wrong clock for all of them: the device's
/// wall time can be corrected forwards or backwards at any moment, and a
/// backward correction makes an elapsed measurement *shrink*, deferring the
/// bound until the clock catches up.
///
/// `ContinuousClock` cannot be moved and keeps counting while the device is
/// asleep, which is the direction that keeps a safety bound honest.
public enum MonotonicClock {
    public static func now() -> ContinuousClock.Instant { ContinuousClock.now }

    /// Seconds elapsed since `start`. `Duration` is exact; this is the one
    /// place it is turned back into the `TimeInterval` the pure policies speak.
    public static func elapsedSeconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return TimeInterval(elapsed.components.seconds)
            + TimeInterval(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
