import Foundation

// MARK: - Auto-Correction Candidate

/// A candidate correction detected from user edits after transcription insertion.
/// When seen multiple times, candidates are promoted to PersonalLexiconRules.
public struct AutoCorrectionCandidate: Identifiable, Codable, Equatable {
  public let id: UUID
  public var original: String        // The word(s) from transcription that was corrected
  public var corrected: String       // What the user changed it to
  public var seenCount: Int          // Number of times this correction was observed
  public var firstSeenAt: Date
  public var lastSeenAt: Date
  public var sourceApps: Set<String> // Apps where this correction was observed
  public var dismissed: Bool         // User chose to ignore this candidate

  public init(
    id: UUID = UUID(),
    original: String,
    corrected: String,
    seenCount: Int = 1,
    firstSeenAt: Date = Date(),
    lastSeenAt: Date = Date(),
    sourceApps: Set<String> = [],
    dismissed: Bool = false
  ) {
    self.id = id
    self.original = original
    self.corrected = corrected
    self.seenCount = seenCount
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt
    self.sourceApps = sourceApps
    self.dismissed = dismissed
  }

  /// Key used to identify duplicate candidates (case-insensitive)
  public var matchKey: String {
    "\(original.lowercased())→\(corrected.lowercased())"
  }

  public func incrementingSeen(app: String?) -> AutoCorrectionCandidate {
    var copy = self
    copy.seenCount += 1
    copy.lastSeenAt = Date()
    if let app, !app.isEmpty {
      copy.sourceApps.insert(app)
    }
    return copy
  }
}

// MARK: - Word Diff Result

/// Represents a single word-level change detected between original and edited text.
public struct WordChange: Equatable, Hashable {
  public enum ChangeType: String, Codable {
    case replacement  // Single word replaced with another single word
    case split        // One word became multiple words
    case merge        // Multiple words became one word
  }

  public let type: ChangeType
  public let original: String   // The original word(s)
  public let corrected: String  // The corrected word(s)

  public init(type: ChangeType, original: String, corrected: String) {
    self.type = type
    self.original = original
    self.corrected = corrected
  }

  /// Check if this looks like a valid correction (not a complete rewrite)
  public var isLikelyCorrection: Bool {
    let origLower = original.lowercased()
    let corrLower = corrected.lowercased()

    // Skip if either is very short (likely noise)
    guard original.count >= 2, corrected.count >= 2 else { return false }

    // Skip if they're exactly identical (including case)
    guard original != corrected else { return false }

    switch type {
    case .replacement:
      // For replacements, check similarity (at least some overlap)
      let similarity = stringSimilarity(origLower, corrLower)
      // Accept if >30% similar (catches typos like Suzy→Susie)
      // or if it's a case-only change (speak → Speak)
      return similarity > 0.3 || origLower == corrLower

    case .split:
      // For splits like "gonna" → "going to", the merged form should contain parts
      // Check if original contains start of first corrected word
      let correctedWords = corrected.split(separator: " ")
      if let firstWord = correctedWords.first {
        return origLower.hasPrefix(String(firstWord.prefix(2)).lowercased())
      }
      return true

    case .merge:
      // For merges like "can not" → "cannot", check if corrected contains both
      let originalWords = original.split(separator: " ")
      return originalWords.allSatisfy { word in
        corrLower.contains(word.lowercased())
      }
    }
  }

  /// Simple string similarity based on common character sequences
  private func stringSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let lhsChars = Array(lhs)
    let rhsChars = Array(rhs)
    let maxLen = max(lhsChars.count, rhsChars.count)
    guard maxLen > 0 else { return 1.0 }

    var matches = 0
    let minLen = min(lhsChars.count, rhsChars.count)
    for index in 0..<minLen where lhsChars[index] == rhsChars[index] {
      matches += 1
    }

    // Also check if one contains the other
    if lhs.contains(rhs) || rhs.contains(lhs) {
      return 0.7
    }

    return Double(matches) / Double(maxLen)
  }
}

// MARK: - Rule Source

/// Indicates how a PersonalLexiconRule was created.
public enum PersonalLexiconRuleSource: String, Codable {
  case manual     // User created manually
  case automatic  // Auto-promoted from correction candidate
}
