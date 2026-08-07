import Foundation

/// Apps whose accessibility implementations are known to handle ranged
/// selected-text replacement well enough for progressive streaming insertion
/// (issue #611). Everything else keeps the standard paste-at-end delivery,
/// even with the experimental setting enabled.
enum StreamingInsertionAllowlist {
  static let bundleIdentifiers: Set<String> = [
    "com.apple.TextEdit",
    "com.apple.Notes",
    // Slack (Electron)
    "com.tinyspeck.slackmacgap",
    // VS Code (Electron)
    "com.microsoft.VSCode",
    // Browsers: focused web text fields expose selected-text range replacement
    "com.apple.Safari",
    "com.google.Chrome"
  ]

  static func allows(_ target: TextOutputTarget?) -> Bool {
    guard let bundleIdentifier = target?.bundleIdentifier else { return false }
    return self.bundleIdentifiers.contains(bundleIdentifier)
  }
}
