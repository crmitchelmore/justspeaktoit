import Foundation

/// Level-based silence auto-stop for one recording. Settings are captured when
/// monitoring starts so the 30 Hz meter callback never reads `@Published`
/// settings on the hot path.
struct SilenceAutoStop {
  struct Settings: Equatable {
    var enabled: Bool
    var threshold: Float
    var duration: TimeInterval

    static let off = Settings(enabled: false, threshold: 0, duration: 0)
  }

  private(set) var settings: Settings = .off
  private(set) var silenceStartedAt: Date?

  mutating func begin(_ settings: Settings) {
    self.settings = settings
    silenceStartedAt = nil
  }

  mutating func reset() {
    silenceStartedAt = nil
  }

  /// Feeds one meter reading. Returns how long the input has been silent when
  /// the session should stop now, and forgets the silence so it fires once.
  ///
  /// `eligible` is false when nothing should auto-stop: no recording, or a
  /// hands-free capture, whose speech detector owns its own silence hold.
  mutating func observe(level: Float, eligible: Bool, now: Date = Date()) -> TimeInterval? {
    guard settings.enabled, eligible, level < settings.threshold else {
      silenceStartedAt = nil
      return nil
    }
    guard let startedAt = silenceStartedAt else {
      silenceStartedAt = now
      return nil
    }
    let silentDuration = now.timeIntervalSince(startedAt)
    guard silentDuration >= settings.duration else { return nil }
    silenceStartedAt = nil
    return silentDuration
  }
}
