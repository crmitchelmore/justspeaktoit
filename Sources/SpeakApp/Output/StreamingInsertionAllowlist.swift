import Foundation

/// Apps whose accessibility implementations are known to handle ranged
/// selected-text replacement well enough for progressive streaming insertion
/// (issue #611). Everything else keeps the standard paste-at-end delivery,
/// even with the experimental setting enabled.
///
/// Membership requires more than accepting a ranged write: the streamed region
/// is re-read through `kAXValue` before every patch, so an app must also report
/// its full field text back reliably. Web areas and custom text views (Electron
/// apps such as Slack and VS Code, and `contenteditable` fields in Safari and
/// Chrome) frequently return no value at all, which leaves the streamed region
/// unverifiable and pauses streaming after the first partial. Those apps are
/// deliberately excluded until the region can be verified through a
/// value-independent route.
enum StreamingInsertionAllowlist {
  static let bundleIdentifiers: Set<String> = [
    "com.apple.TextEdit",
    "com.apple.Notes"
  ]

  static func allows(_ target: TextOutputTarget?) -> Bool {
    guard let bundleIdentifier = target?.bundleIdentifier else { return false }
    return self.bundleIdentifiers.contains(bundleIdentifier)
  }
}
