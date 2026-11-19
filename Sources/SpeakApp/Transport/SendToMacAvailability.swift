import SpeakCore

/// Whether this build ships the Send to Mac receiver.
///
/// The Mac App Store build has no `com.apple.security.network.server`
/// entitlement and no shipping app can connect to the receiver, so App Store
/// builds compile it out: no listener, no Settings card, no search entry.
enum SendToMacAvailability {
  static let settingsSearchEntryID = "general.sendToMac"

  #if APP_STORE
  static let isAvailable = false
  #else
  static let isAvailable = true
  #endif

  /// Removes the Send to Mac search entry when the receiver is unavailable, so
  /// search never offers a card the build does not render.
  static func filter(_ entries: [SettingsSearchEntry], isAvailable: Bool = isAvailable) -> [SettingsSearchEntry] {
    isAvailable ? entries : entries.filter { $0.id != settingsSearchEntryID }
  }
}
