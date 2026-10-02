import Foundation

/// Splits text longer than a speech provider's per-request limit into ordered
/// segments that can be spoken one after another.
///
/// Segments end at sentence boundaries where possible, otherwise at the last
/// whitespace that fits, and only as a last resort inside a word. A grapheme
/// cluster (an emoji sequence or a letter with combining marks) is never
/// divided. Each segment is trimmed and at most `limit` Unicode scalars, the
/// unit Deepgram counts. Concatenating the segments with single spaces keeps
/// every non-whitespace character in order; runs of whitespace between
/// segments are not preserved.
public enum SpeechTextSegmenter {
    public static func segments(
        _ text: String, limit: Int = DeepgramSpeechRequest.maximumCharacters
    ) -> [String] {
        precondition(limit > 0, "A segment limit must be positive")
        var segments: [String] = []
        var current = ""
        var currentCount = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
            currentCount = 0
        }

        for sentence in sentences(in: text) {
            let count = sentence.unicodeScalars.count
            if currentCount + count <= limit {
                current += sentence
                currentCount += count
                continue
            }
            flush()
            if count <= limit {
                current = sentence
                currentCount = count
            } else {
                for piece in split(sentence, limit: limit) { segments.append(piece) }
            }
        }
        flush()
        return segments
    }

    /// Sentences including their trailing whitespace, so joining them restores the text.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var endedSentence = false
        for character in text {
            if endedSentence, !character.isWhitespace {
                result.append(current)
                current = ""
                endedSentence = false
            }
            current.append(character)
            if character.isNewline || ".!?…".contains(character) { endedSentence = true }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A sentence longer than the limit: break at the last whitespace that
    /// fits, or inside a word when a single word exceeds the limit.
    private static func split(_ sentence: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var remaining = Substring(sentence)
        while true {
            let trimmedRemaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedRemaining.unicodeScalars.count <= limit {
                if !trimmedRemaining.isEmpty { pieces.append(trimmedRemaining) }
                return pieces
            }
            remaining = remaining.drop { $0.isWhitespace }
            var end = remaining.startIndex
            var lastBreak: Substring.Index?
            var count = 0
            for index in remaining.indices {
                let scalars = remaining[index].unicodeScalars.count
                if count + scalars > limit { break }
                count += scalars
                end = remaining.index(after: index)
                if remaining[index].isWhitespace { lastBreak = index }
            }
            if end == remaining.startIndex {
                // A single grapheme longer than the limit cannot be divided.
                end = remaining.index(after: remaining.startIndex)
            } else if let lastBreak, lastBreak > remaining.startIndex {
                end = lastBreak
            }
            let piece = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            remaining = remaining[end...]
        }
    }
}
