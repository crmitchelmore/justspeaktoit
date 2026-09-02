#if os(macOS)
import Foundation

/// Chooses how often `FnKeyBackend` probes the Fn hardware state.
///
/// The probe is a *fallback*: the CGEvent tap normally delivers Fn edges
/// immediately, so a slow baseline poll costs nothing in the common case while
/// letting the OS coalesce timers and letting the app nap in the menu bar.
/// The poll escalates to the old 50 Hz cadence only in the situations where the
/// tap is known to be unreliable:
///
/// - the Fn key is currently held (a missed key-up would strand a hold), or
/// - a secure-input client (Terminal, password fields) is active and can starve
///   tap and monitor callbacks, or
/// - the tap was just disabled by timeout/user input and has been re-enabled,
///   so edges may have been dropped while it was off.
///
/// This type is intentionally pure so the cadence decision is testable without
/// touching real HID state.
enum FnKeyPollingPolicy {
  /// Idle cadence: 5 Hz.
  static let baselineInterval: TimeInterval = 0.2

  /// Escalated cadence: 50 Hz, matching the historical fixed-rate poll.
  static let escalatedInterval: TimeInterval = 0.02

  /// Fraction of the interval the OS may shift a baseline tick by, so it can be
  /// coalesced with other timers.
  static let baselineToleranceFraction: Double = 0.2

  /// How long an event-tap disable keeps the poll escalated.
  static let tapRecoveryWindow: TimeInterval = 2.0

  /// The poll interval to use for the given conditions.
  static func interval(
    isPressed: Bool,
    secureInput: Bool,
    recentTapRecovery: Bool
  ) -> TimeInterval {
    if isPressed || secureInput || recentTapRecovery {
      return Self.escalatedInterval
    }
    return Self.baselineInterval
  }

  /// Timer tolerance for a given interval: 20% while idle so ticks coalesce,
  /// none while escalated so gesture latency is unaffected.
  static func tolerance(for interval: TimeInterval) -> TimeInterval {
    guard interval >= Self.baselineInterval else { return 0 }
    return interval * Self.baselineToleranceFraction
  }

  /// Whether a tap disable at `disabledAtUptime` still forces escalation at `nowUptime`.
  ///
  /// A `nil` timestamp means the tap has not been disabled since `start()`.
  static func isWithinTapRecoveryWindow(
    disabledAtUptime: TimeInterval?,
    nowUptime: TimeInterval
  ) -> Bool {
    guard let disabledAtUptime else { return false }
    let elapsed = nowUptime - disabledAtUptime
    return elapsed >= 0 && elapsed < Self.tapRecoveryWindow
  }
}

#endif
