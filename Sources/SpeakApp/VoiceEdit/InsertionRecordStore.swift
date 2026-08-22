import Foundation

/// A UTF-16 range inside a text field, as accessibility reports it.
struct VoiceEditTextRange: Equatable, Sendable {
  let location: Int
  let length: Int

  init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }

  init(_ range: CFRange) {
    self.init(location: range.location, length: range.length)
  }

  var cfRange: CFRange {
    CFRange(location: location, length: length)
  }

  var end: Int { location + length }

  /// The substring of `value` this range covers, or nil when the range no
  /// longer fits the value.
  func substring(of value: String) -> String? {
    let utf16 = value.utf16
    guard location >= 0, length >= 0, end <= utf16.count,
      let start = utf16.index(utf16.startIndex, offsetBy: location, limitedBy: utf16.endIndex),
      let finish = utf16.index(start, offsetBy: length, limitedBy: utf16.endIndex)
    else { return nil }
    return String(utf16[start..<finish])
  }
}

/// Where normal dictation last put text: the field, the exact UTF-16 range
/// and the text written there. Voice Edit's "last dictation" fallback edits
/// this range, never a text search that could pick a different occurrence
/// (issue #673).
struct InsertionRecord {
  let target: TextOutputTarget
  let range: VoiceEditTextRange
  let text: String
  let recordedAt: Date
}

@MainActor
final class InsertionRecordStore {
  private(set) var latest: InsertionRecord?

  func record(_ record: InsertionRecord) {
    latest = record
  }

  func clear() {
    latest = nil
  }
}
