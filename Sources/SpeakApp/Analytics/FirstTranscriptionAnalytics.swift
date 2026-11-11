import Foundation
import SpeakCore

/// The one-time "first transcription succeeded" product event: which provider
/// family and engine produced it, and how long after install. Emits at most
/// once per install, tracked in `defaults`.
struct FirstTranscriptionAnalytics {
  static let emittedKey = "analytics.firstTranscriptionSucceeded.emitted"
  static let installDateKey = "analytics.installDate"

  let defaults: UserDefaults
  var now: () -> Date = Date.init

  /// The event to send for this transcription, or nil when it was already
  /// sent. Marks it sent, and records the install date on first use.
  func eventIfFirst(modelIdentifier: String, isOnDevice: Bool) -> ProductAnalyticsEvent? {
    guard !defaults.bool(forKey: Self.emittedKey) else { return nil }
    let installDate = defaults.object(forKey: Self.installDateKey) as? Date ?? now()
    if defaults.object(forKey: Self.installDateKey) == nil { defaults.set(installDate, forKey: Self.installDateKey) }
    let days = max(0, Calendar.current.dateComponents([.day], from: installDate, to: now()).day ?? 0)
    defaults.set(true, forKey: Self.emittedKey)
    return .firstTranscriptionSucceeded(
      provider: Self.provider(for: modelIdentifier),
      engine: isOnDevice ? .onDevice : .cloud,
      daysSinceInstall: Self.bucket(forDaysSinceInstall: days)
    )
  }

  static func provider(for modelIdentifier: String) -> AnalyticsProviderType {
    let identifier = modelIdentifier.lowercased()
    if identifier.contains("deepgram") { return .deepgram }
    if identifier.contains("soniox") { return .soniox }
    if identifier.contains("openai") { return .openAI }
    if identifier.contains("apple") { return .apple }
    if identifier.contains("whisper") || identifier.contains("fluid") { return .local }
    return .other
  }

  static func bucket(forDaysSinceInstall days: Int) -> AnalyticsDaysSinceInstallBucket {
    switch days {
    case ...0: return .zero
    case 1: return .one
    case 2...7: return .twoToSeven
    case 8...30: return .eightToThirty
    default: return .overThirty
    }
  }
}
