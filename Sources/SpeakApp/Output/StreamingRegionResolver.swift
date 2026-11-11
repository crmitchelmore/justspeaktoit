import Foundation

/// Locates the region a ranged streaming session wrote in the target field,
/// from the field's text alone.
enum StreamingRegionResolver {
  /// State of the streamed region as observed in the live target field.
  enum State: Equatable {
    /// The streamed text is present at the given UTF-16 offset.
    case matched(anchor: Int)
    /// The field was read successfully and provably holds none of the streamed text.
    case absent
    /// The field could not be read, or the streamed text is ambiguous.
    case unknown
  }

  /// Where the streamed text is now. Kept pure so the never-duplicate and
  /// never-overwrite rules are unit-testable without AX.
  ///
  /// - `.absent` is returned only when the field cannot be hiding an altered
  ///   copy of the streamed text: the field is empty, or it has not grown since
  ///   the region was anchored. Anything else (an app that autocorrected,
  ///   reformatted or smart-quoted the streamed text) is `.unknown`, because
  ///   handing such a session back to the standard delivery would duplicate it.
  /// - Re-anchoring on a unique occurrence is refused when the field already
  ///   contained that text before this session wrote anything, since the match
  ///   may be unrelated pre-existing content.
  static func resolve(
    fieldText: String,
    expected: String,
    anchor: Int,
    baselineFieldText: String?
  ) -> State {
    guard !expected.isEmpty else {
      return anchor <= fieldText.utf16.count ? .matched(anchor: anchor) : .unknown
    }

    if self.utf16Substring(of: fieldText, location: anchor, length: expected.utf16.count) == expected {
      return .matched(anchor: anchor)
    }

    // The app shifted the text (autocorrect, an edit above the region, …).
    // Re-anchor only when the streamed text appears exactly once and cannot be
    // confused with content that was already in the field.
    let offsets = self.utf16Offsets(of: expected, in: fieldText, limit: 2)
    if offsets.count == 1, let offset = offsets.first {
      if let baseline = baselineFieldText, baseline.range(of: expected, options: .literal) != nil {
        return .unknown
      }
      return .matched(anchor: offset)
    }
    guard offsets.isEmpty else { return .unknown }

    if fieldText.isEmpty { return .absent }
    guard let baseline = baselineFieldText, fieldText.utf16.count <= baseline.utf16.count else {
      return .unknown
    }
    return .absent
  }

  /// UTF-16 based substring with bounds checks; `nil` when the range is out of
  /// bounds or splits a surrogate pair.
  static func utf16Substring(of text: String, location: Int, length: Int) -> String? {
    let utf16 = text.utf16
    guard location >= 0, length >= 0, location + length <= utf16.count else { return nil }
    let start = utf16.index(utf16.startIndex, offsetBy: location)
    let end = utf16.index(start, offsetBy: length)
    guard let startIndex = start.samePosition(in: text),
          let endIndex = end.samePosition(in: text)
    else { return nil }
    return String(text[startIndex..<endIndex])
  }

  /// UTF-16 offsets of up to `limit` occurrences of `needle` in `haystack`.
  static func utf16Offsets(of needle: String, in haystack: String, limit: Int) -> [Int] {
    guard !needle.isEmpty, limit > 0 else { return [] }
    var offsets: [Int] = []
    var searchStart = haystack.startIndex
    // `.literal` matches exact scalar sequences, the same rule
    // `StreamingTextReconciler.diff` uses to compute replacement offsets. Without
    // it a canonically equivalent match (decomposed vs precomposed accents) would
    // re-anchor the region onto text of a different UTF-16 length and desynchronise
    // every later patch.
    while offsets.count < limit, searchStart < haystack.endIndex,
          let found = haystack.range(
            of: needle, options: .literal, range: searchStart..<haystack.endIndex
          ) {
      offsets.append(found.lowerBound.utf16Offset(in: haystack))
      searchStart = haystack.index(after: found.lowerBound)
    }
    return offsets
  }
}
