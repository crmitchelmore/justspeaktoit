import Foundation

/// Represents the live transcript state with three distinct segments for speed-first rendering.
/// - `stablePrefix`: Committed final segments that are never rewritten (except in aggressive mode)
/// - `polishedTail`: Recently polished text from fast-lane LLM (replaces raw tail for display)
/// - `unstableTail`: Current interim hypothesis from STT (changes frequently)
@MainActor
final class TranscriptStateModel: ObservableObject {
  /// Committed final segments - stable and rarely rewritten
  @Published private(set) var stablePrefix: String = ""

  /// Fast-lane polished version of recent text (optional overlay)
  @Published private(set) var polishedTail: String = ""

  /// Current interim hypothesis from STT engine
  @Published private(set) var unstableTail: String = ""

  /// Individual segments with timing for reconciliation
  @Published private(set) var segments: [TranscriptSegment] = []

  /// The combined display text: stablePrefix + polishedTail (or raw tail) + unstableTail
  var displayText: String {
    let stable = stablePrefix
    let tail = polishedTail.isEmpty ? rawTailText : polishedTail
    let interim = unstableTail

    var result = stable
    if !tail.isEmpty {
      if !result.isEmpty && !result.hasSuffix(" ") && !tail.hasPrefix(" ") {
        result += " "
      }
      result += tail
    }
    if !interim.isEmpty {
      if !result.isEmpty && !result.hasSuffix(" ") && !interim.hasPrefix(" ") {
        result += " "
      }
      result += interim
    }
    return result
  }

  /// Raw tail text (unpolished recent segments)
  private(set) var rawTailText: String = ""

  /// Character offset where the tail begins (for patch protocol)
  private(set) var tailStartOffset: Int = 0

  /// Segments that are in the "tail" window (not yet committed to stable)
  private var tailSegments: [TranscriptSegment] = []

  /// Configuration for tail window size
  var tailWindowCharacters: Int = 600

  struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    let startMs: Int
    let endMs: Int
    let text: String
    let isFinal: Bool
  }

  func reset() {
    stablePrefix = ""
    polishedTail = ""
    unstableTail = ""
    rawTailText = ""
    segments = []
    tailSegments = []
    tailStartOffset = 0
  }

  /// Called when STT emits an interim (unstable) hypothesis
  func updateInterim(_ text: String) {
    unstableTail = text
  }

  /// Called when STT emits a final segment
  func commitSegment(_ segment: TranscriptSegment) {
    segments.append(segment)
    tailSegments.append(segment)

    rebuildTailWindow()
  }

  /// Called when an utterance boundary is detected (pause/VAD/endpoint)
  /// Commits all tail segments to stable prefix
  func commitUtteranceBoundary() {
    guard !tailSegments.isEmpty else { return }

    let tailText = tailSegments.map(\.text).joined(separator: " ")
    let finalText = polishedTail.isEmpty ? tailText : polishedTail

    if !stablePrefix.isEmpty && !finalText.isEmpty {
      stablePrefix += " "
    }
    stablePrefix += finalText

    tailSegments.removeAll()
    polishedTail = ""
    rawTailText = ""
    unstableTail = ""
    tailStartOffset = stablePrefix.count
  }

  /// Apply a polished tail from the fast-lane LLM
  func applyPolishedTail(_ polished: String) {
    polishedTail = polished
  }

  /// Clear the polished tail (e.g., when new interim arrives and we want fresh polish)
  func clearPolishedTail() {
    polishedTail = ""
  }

  /// Get the current tail context for sending to LLM
  /// Returns: (stableContext, tailText, tailCharCount)
  func tailContext(maxStableContext: Int = 200) -> (stableContext: String, tailText: String) {
    let stableContext = String(stablePrefix.suffix(maxStableContext))
    return (stableContext, rawTailText)
  }

  /// Rebuild the tail window based on character limit
  private func rebuildTailWindow() {
    // Build raw tail from tail segments
    rawTailText = tailSegments.map(\.text).joined(separator: " ")

    // If tail exceeds window, move oldest segments to stable
    while rawTailText.count > tailWindowCharacters && tailSegments.count > 1 {
      let oldest = tailSegments.removeFirst()
      let oldestText = oldest.text

      if !stablePrefix.isEmpty && !oldestText.isEmpty {
        stablePrefix += " "
      }
      stablePrefix += oldestText

      rawTailText = tailSegments.map(\.text).joined(separator: " ")
    }

    tailStartOffset = stablePrefix.count
    // Clear polished tail when raw tail changes significantly
    polishedTail = ""
  }
}
