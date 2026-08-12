import Foundation

/// One minimal edit for a text document: delete `deleteCount` user-perceived
/// characters immediately before the cursor, then insert `insertion` there.
public struct KeyboardTranscriptEdit: Equatable, Sendable {
    public let deleteCount: Int
    public let insertion: String

    public init(deleteCount: Int, insertion: String) {
        self.deleteCount = deleteCount
        self.insertion = insertion
    }

    public var isNoop: Bool {
        deleteCount == 0 && insertion.isEmpty
    }
}

/// Turns successive full transcription hypotheses into minimal document edits
/// using a stable-prefix commit and volatile-tail replacement strategy.
///
/// Live speech engines resend the whole transcript with every partial result
/// and mostly revise only the trailing words. Rewriting the full text in a
/// `UITextDocumentProxy` on every partial causes visible churn and slow
/// per-character deletes, so this streamer:
///
/// - keeps a **committed prefix** that is never rewritten once promoted;
/// - keeps a **volatile tail** that each new hypothesis may replace;
/// - promotes tail words to the committed prefix only after they survive one
///   revision unchanged, always on a word boundary, and never the final
///   ``holdbackWordCount`` words (engines revise those most).
///
/// Invariant: an emitted `deleteCount` never exceeds the current volatile
/// tail's length, so the streamer can never delete host-app text or its own
/// committed prefix.
public struct KeyboardTranscriptStreamer: Equatable, Sendable {
    /// Words at the end of a hypothesis that stay volatile even when two
    /// consecutive hypotheses agree.
    public static let holdbackWordCount = 2

    public private(set) var committedText = ""
    public private(set) var volatileTail = ""

    public init() {}

    /// Everything this streamer has inserted into the document so far.
    public var insertedText: String {
        committedText + volatileTail
    }

    /// A separator to insert before dictation starts so streamed text does not
    /// glue onto existing host text. Returns `nil` when no separator is needed.
    public static func leadingSeparator(contextBeforeInput: String?) -> String? {
        guard let last = contextBeforeInput?.last, !last.isWhitespace else { return nil }
        return " "
    }

    /// Applies the next live hypothesis (the full transcript so far) and
    /// returns the minimal edit that brings the document up to date.
    public mutating func update(hypothesis: String) -> KeyboardTranscriptEdit {
        let previousTail = volatileTail
        let newTail = tail(for: hypothesis)
        let edit = Self.edit(from: previousTail, to: newTail)
        volatileTail = newTail
        promoteStablePrefix(previousTail: previousTail)
        return edit
    }

    /// Applies the final transcript and commits everything. An empty final
    /// transcript keeps whatever partial text is already in the document.
    public mutating func finalize(transcript: String) -> KeyboardTranscriptEdit {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var edit = KeyboardTranscriptEdit(deleteCount: 0, insertion: "")
        if !trimmed.isEmpty {
            let newTail = tail(for: transcript)
            edit = Self.edit(from: volatileTail, to: newTail)
            volatileTail = newTail
        }
        committedText += volatileTail
        volatileTail = ""
        return edit
    }

    /// Forgets all session state without touching the document.
    public mutating func reset() {
        committedText = ""
        volatileTail = ""
    }

    /// The volatile tail that displays `hypothesis` after the committed prefix.
    private func tail(for hypothesis: String) -> String {
        guard !committedText.isEmpty else { return hypothesis }
        if hypothesis.hasPrefix(committedText) {
            return String(hypothesis.dropFirst(committedText.count))
        }
        if committedText.hasPrefix(hypothesis) {
            // The engine shrank below the committed boundary; the committed
            // prefix stays and the volatile tail clears.
            return ""
        }
        // The engine revised text that was already committed. The committed
        // prefix is never rewritten; splice in only what follows the point of
        // divergence, resuming at the next word boundary so partial words are
        // not glued together, and dropping words the committed prefix already
        // ends with so nothing is duplicated.
        let sharedCount = Self.commonPrefix(hypothesis, committedText).count
        let remainder = hypothesis.dropFirst(sharedCount).drop { !$0.isWhitespace }
        let spliced = remainder.trimmingCharacters(in: .whitespaces)
        guard !spliced.isEmpty else { return "" }
        let deduplicated = droppingWordsCommittedAlready(from: spliced)
        guard !deduplicated.isEmpty else { return "" }
        let needsSeparator = committedText.last?.isWhitespace == false
        return needsSeparator ? " " + deduplicated : deduplicated
    }

    /// Removes the longest run of leading words in `candidate` that the
    /// committed prefix already ends with.
    private func droppingWordsCommittedAlready(from candidate: String) -> String {
        let committedWords = committedText.split(whereSeparator: \.isWhitespace)
        var candidateWords = ArraySlice(candidate.split(whereSeparator: \.isWhitespace))
        let maxOverlap = min(committedWords.count, candidateWords.count)
        for overlap in stride(from: maxOverlap, through: 1, by: -1)
        where committedWords.suffix(overlap).elementsEqual(candidateWords.prefix(overlap)) {
            candidateWords.removeFirst(overlap)
            break
        }
        return candidateWords.joined(separator: " ")
    }

    private static func edit(from oldTail: String, to newTail: String) -> KeyboardTranscriptEdit {
        let shared = commonPrefix(oldTail, newTail)
        return KeyboardTranscriptEdit(
            deleteCount: oldTail.count - shared.count,
            insertion: String(newTail.dropFirst(shared.count))
        )
    }

    /// Grapheme-cluster-safe common prefix (Foundation's `commonPrefix(with:)`
    /// compares UTF-16 units and can split a cluster).
    private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var result = ""
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        while lhsIndex < lhs.endIndex, rhsIndex < rhs.endIndex, lhs[lhsIndex] == rhs[rhsIndex] {
            result.append(lhs[lhsIndex])
            lhsIndex = lhs.index(after: lhsIndex)
            rhsIndex = rhs.index(after: rhsIndex)
        }
        return result
    }

    /// Moves tail words that survived one revision unchanged into the
    /// committed prefix, keeping at least ``holdbackWordCount`` words volatile.
    private mutating func promoteStablePrefix(previousTail: String) {
        let stable = Self.commonPrefix(previousTail, volatileTail)
        guard !stable.isEmpty else { return }
        let stableEnd = volatileTail.index(volatileTail.startIndex, offsetBy: stable.count)
        let holdbackStart = Self.startIndexOfTrailingWords(
            in: volatileTail,
            wordCount: Self.holdbackWordCount
        )
        // Commit only whole words: walk back to the last whitespace at or
        // before the limit and commit through it.
        var boundary = min(stableEnd, holdbackStart)
        while boundary > volatileTail.startIndex {
            let previous = volatileTail.index(before: boundary)
            if volatileTail[previous].isWhitespace {
                break
            }
            boundary = previous
        }
        guard boundary > volatileTail.startIndex else { return }
        committedText += volatileTail[..<boundary]
        volatileTail = String(volatileTail[boundary...])
    }

    /// The index where the last `wordCount` words of `text` begin.
    private static func startIndexOfTrailingWords(in text: String, wordCount: Int) -> String.Index {
        var index = text.endIndex
        var remainingWords = wordCount
        while index > text.startIndex, remainingWords > 0 {
            while index > text.startIndex, text[text.index(before: index)].isWhitespace {
                index = text.index(before: index)
            }
            var sawWord = false
            while index > text.startIndex, !text[text.index(before: index)].isWhitespace {
                index = text.index(before: index)
                sawWord = true
            }
            if sawWord {
                remainingWords -= 1
            }
        }
        return index
    }
}
