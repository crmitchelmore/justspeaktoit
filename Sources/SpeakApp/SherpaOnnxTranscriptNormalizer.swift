import Foundation

enum SherpaOnnxTranscriptNormalizer {
  static func normalize(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isUppercaseDominated(trimmed) else { return trimmed }
    return sentenceCase(trimmed.lowercased())
  }

  private static func isUppercaseDominated(_ text: String) -> Bool {
    let scalars = text.unicodeScalars
    let uppercaseCount = scalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
    let lowercaseCount = scalars.filter { CharacterSet.lowercaseLetters.contains($0) }.count
    let letterCount = uppercaseCount + lowercaseCount
    guard letterCount >= 4 else { return false }
    return lowercaseCount == 0 || Double(uppercaseCount) / Double(letterCount) >= 0.85
  }

  private static func sentenceCase(_ text: String) -> String {
    var result = ""
    var shouldCapitalise = true
    for character in text {
      if shouldCapitalise, character.isLetter {
        result.append(String(character).uppercased())
        shouldCapitalise = false
      } else {
        result.append(character)
      }
      if ".!?\n".contains(character) {
        shouldCapitalise = true
      }
    }
    return capitaliseStandaloneI(in: result)
  }

  private static func capitaliseStandaloneI(in text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"\bi\b"#) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "I")
  }
}
