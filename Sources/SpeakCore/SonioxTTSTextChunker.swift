import Foundation

/// Splits long input into request-sized pieces for the batch speech endpoint.
///
/// Soniox refuses a single request above ``SonioxTTSAPI/maxTextLength``, so a
/// caller that must speak a long document sends a sequence of requests and
/// joins the audio. A split prefers the end of a sentence, then a gap between
/// words, and it always falls on a grapheme-cluster boundary. Joining the
/// result returns the trimmed input, so the spoken order matches the written
/// order.
public enum SonioxTTSTextChunker {
    /// Characters per request, kept below Soniox's hard limit for head-room.
    public static let maximumChunkCharacters = 4500

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？"
    ]
    /// Marks that belong to the sentence that precedes them.
    private static let trailingMarks: Set<Character> = [
        "\"", "'", ")", "]", "}", "”", "’", "»", "›"
    ]

    public static func chunks(
        _ text: String,
        maximumCharacters: Int = maximumChunkCharacters
    ) -> [String] {
        guard maximumCharacters > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        var remaining = trimmed[...]
        while !remaining.isEmpty {
            guard let limit = remaining.index(
                remaining.startIndex,
                offsetBy: maximumCharacters,
                limitedBy: remaining.endIndex
            ), limit != remaining.endIndex else {
                chunks.append(String(remaining))
                break
            }
            let split = sentenceBoundary(in: remaining, before: limit)
                ?? wordBoundary(in: remaining, before: limit)
                ?? limit
            chunks.append(String(remaining[..<split]))
            remaining = remaining[split...]
        }
        return chunks
    }

    /// The last sentence end at or before `limit`, or `nil` when the window
    /// holds no sentence end. Whitespace after the terminator stays with the
    /// sentence it closes.
    private static func sentenceBoundary(
        in text: Substring,
        before limit: String.Index
    ) -> String.Index? {
        var index = limit
        while index > text.startIndex {
            index = text.index(before: index)
            guard sentenceTerminators.contains(text[index]) else { continue }

            var end = text.index(after: index)
            while end < limit, trailingMarks.contains(text[end]) {
                end = text.index(after: end)
            }
            // A terminator inside a number or an address does not end a
            // sentence, so whitespace must follow it.
            guard end <= limit, end < text.endIndex, text[end].isWhitespace else { continue }

            var split = end
            while split < limit, text[split].isWhitespace {
                split = text.index(after: split)
            }
            return split
        }
        return nil
    }

    /// The last gap between words at or before `limit`.
    private static func wordBoundary(
        in text: Substring,
        before limit: String.Index
    ) -> String.Index? {
        guard let whitespace = text[..<limit].lastIndex(where: { $0.isWhitespace }) else {
            return nil
        }
        var split = text.index(after: whitespace)
        while split < limit, text[split].isWhitespace {
            split = text.index(after: split)
        }
        return split
    }
}
