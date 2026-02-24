import Foundation

/// Detects word-level changes between original and edited text.
/// Focuses on finding direct replacements rather than general rewrites.
struct WordDiffer {
  /// Minimum word length to consider for corrections
  static let minimumWordLength = 2

  /// Find word-level changes between the original inserted text and the edited version.
  /// Returns only changes that look like intentional corrections (not rewrites).
  static func findChanges(original: String, edited: String) -> [WordChange] {
    let originalWords = tokenize(original)
    let editedWords = tokenize(edited)

    // If the text is completely different, don't try to extract corrections
    guard !originalWords.isEmpty, !editedWords.isEmpty else { return [] }

    // Find the longest common prefix and suffix to isolate the changed region
    let (prefixLen, suffixLen) = findCommonEnds(originalWords, editedWords)

    // Extract the changed portions
    let originalMiddle = Array(
      originalWords.dropFirst(prefixLen).dropLast(max(0, suffixLen)))
    let editedMiddle = Array(editedWords.dropFirst(prefixLen).dropLast(max(0, suffixLen)))

    // If nothing changed or too much changed, skip
    guard !originalMiddle.isEmpty || !editedMiddle.isEmpty else { return [] }

    // If the change is too large (more than 5 words difference), likely a rewrite
    if abs(originalMiddle.count - editedMiddle.count) > 5 { return [] }
    if originalMiddle.count > 10 || editedMiddle.count > 10 { return [] }

    // Try to extract individual word replacements
    return extractWordChanges(original: originalMiddle, edited: editedMiddle)
  }

  /// Tokenize text into words, preserving case but trimming punctuation for matching.
  private static func tokenize(_ text: String) -> [String] {
    text
      .components(separatedBy: .whitespacesAndNewlines)
      .map { $0.trimmingCharacters(in: .punctuationCharacters) }
      .filter { !$0.isEmpty }
  }

  /// Find the length of common prefix and suffix in word arrays.
  private static func findCommonEnds(_ a: [String], _ b: [String]) -> (prefix: Int, suffix: Int) {
    // Find common prefix length
    var prefixLen = 0
    let minLen = min(a.count, b.count)
    while prefixLen < minLen && a[prefixLen].lowercased() == b[prefixLen].lowercased() {
      prefixLen += 1
    }

    // Find common suffix length (not overlapping with prefix)
    var suffixLen = 0
    let maxSuffix = minLen - prefixLen
    while suffixLen < maxSuffix
      && a[a.count - 1 - suffixLen].lowercased() == b[b.count - 1 - suffixLen].lowercased()
    {
      suffixLen += 1
    }

    return (prefixLen, suffixLen)
  }

  /// Extract individual word changes from the differing middle portions.
  private static func extractWordChanges(original: [String], edited: [String]) -> [WordChange] {
    var changes: [WordChange] = []

    // Handle different scenarios
    if original.count == edited.count {
      // Same word count - look for 1:1 replacements
      for (orig, edit) in zip(original, edited) {
        // Detect any change including case-only changes (speak → Speak)
        if orig != edit && orig.count >= minimumWordLength
          && edit.count >= minimumWordLength
        {
          let change = WordChange(type: .replacement, original: orig, corrected: edit)
          if change.isLikelyCorrection {
            changes.append(change)
          }
        }
      }
    } else if original.count == 1 && edited.count > 1 && edited.count <= 3 {
      // Split: one word became multiple (e.g., "gonna" → "going to")
      let change = WordChange(
        type: .split,
        original: original[0],
        corrected: edited.joined(separator: " ")
      )
      if change.isLikelyCorrection {
        changes.append(change)
      }
    } else if original.count > 1 && original.count <= 3 && edited.count == 1 {
      // Merge: multiple words became one (e.g., "can not" → "cannot")
      let change = WordChange(
        type: .merge,
        original: original.joined(separator: " "),
        corrected: edited[0]
      )
      if change.isLikelyCorrection {
        changes.append(change)
      }
    } else if original.count > edited.count {
      // More words in original - try to find individual replacements via LCS
      changes.append(contentsOf: extractViaLCS(original: original, edited: edited))
    } else {
      // More words in edited - try to find individual replacements via LCS
      changes.append(contentsOf: extractViaLCS(original: original, edited: edited))
    }

    return changes
  }

  /// Use longest common subsequence to align words and find replacements.
  private static func extractViaLCS(original: [String], edited: [String]) -> [WordChange] {
    // Build LCS table
    let m = original.count
    let n = edited.count
    guard m > 0, n > 0 else { return [] }
    var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

    for i in 1...m {
      for j in 1...n {
        if original[i - 1].lowercased() == edited[j - 1].lowercased() {
          dp[i][j] = dp[i - 1][j - 1] + 1
        } else {
          dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
        }
      }
    }

    // Backtrack to find which words are in common
    var commonOriginalIndices = Set<Int>()
    var commonEditedIndices = Set<Int>()
    var i = m, j = n
    while i > 0 && j > 0 {
      if original[i - 1].lowercased() == edited[j - 1].lowercased() {
        commonOriginalIndices.insert(i - 1)
        commonEditedIndices.insert(j - 1)
        i -= 1
        j -= 1
      } else if dp[i - 1][j] > dp[i][j - 1] {
        i -= 1
      } else {
        j -= 1
      }
    }

    // Find words that are not in common
    let changedOriginal = original.enumerated()
      .filter { !commonOriginalIndices.contains($0.offset) }
      .map { $0.element }
    let changedEdited = edited.enumerated()
      .filter { !commonEditedIndices.contains($0.offset) }
      .map { $0.element }

    // If we have 1:1 mapping of changed words, treat as replacements
    var changes: [WordChange] = []
    if changedOriginal.count == changedEdited.count && changedOriginal.count <= 3 {
      for (orig, edit) in zip(changedOriginal, changedEdited) {
        if orig.count >= minimumWordLength && edit.count >= minimumWordLength {
          let change = WordChange(type: .replacement, original: orig, corrected: edit)
          if change.isLikelyCorrection {
            changes.append(change)
          }
        }
      }
    }

    return changes
  }
}
