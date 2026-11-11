import Foundation
import SpeakCore

/// The `UserDefaults` reads and writes shared by `AppSettings` and its domain
/// preference stores, so every store honours the same persistence suppression.
@MainActor
final class AppSettingsPersistence {
  let defaults: UserDefaults

  /// When true, `store` skips writing to `UserDefaults` while the published
  /// in-memory values still update. See `AppSettings.suppressesPersistence`.
  var isSuppressed = false

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  func store<T>(_ value: T, key: ApplicationPreferenceKey) {
    guard !isSuppressed else { return }
    switch value {
    case let boolValue as Bool:
      defaults.set(boolValue, forKey: key.rawValue)
    case let stringValue as String:
      defaults.set(stringValue, forKey: key.rawValue)
    case let doubleValue as Double:
      defaults.set(doubleValue, forKey: key.rawValue)
    case let arrayValue as [String]:
      defaults.set(arrayValue, forKey: key.rawValue)
    default:
      defaults.set(value, forKey: key.rawValue)
    }
  }

  /// A stored `Bool`, or `fallback` when the key is missing or holds another type.
  func flag(_ key: ApplicationPreferenceKey, default fallback: Bool) -> Bool {
    defaults.object(forKey: key.rawValue) as? Bool ?? fallback
  }

  /// A stored `Double`, or `fallback` when the key is missing or holds another type.
  func number(_ key: ApplicationPreferenceKey, default fallback: Double) -> Double {
    defaults.object(forKey: key.rawValue) as? Double ?? fallback
  }

  /// A stored `Int`, or `fallback` when the key is missing or holds another type.
  func integer(_ key: ApplicationPreferenceKey, default fallback: Int) -> Int {
    defaults.object(forKey: key.rawValue) as? Int ?? fallback
  }

  /// A stored raw value naming a case, or `fallback`.
  func choice<Choice: RawRepresentable>(
    _ key: ApplicationPreferenceKey, default fallback: Choice
  ) -> Choice where Choice.RawValue == String {
    Choice(rawValue: defaults.string(forKey: key.rawValue) ?? fallback.rawValue) ?? fallback
  }

  func strings(_ key: ApplicationPreferenceKey) -> [String] {
    defaults.array(forKey: key.rawValue) as? [String] ?? []
  }
}
