import Foundation

/// Word-level comparison of two transcripts of the same audio.
///
/// `WordDiffer` is tuned to recognise a user's small corrections and
/// deliberately returns nothing for larger divergences, so it cannot drive a
/// side-by-side view where whole clauses may differ. This differ is the
/// general form: a longest-common-subsequence alignment that reports every
/// word as kept, inserted (only in the candidate) or deleted (only in the
/// reference). Words are matched case- and punctuation-insensitively so
/// "Hello," and "hello" count as the same word; the original spelling is
/// preserved for display.
public enum TranscriptWordDiff {
    public enum Kind: Sendable, Hashable {
        case equal
        case inserted
        case deleted
    }

    public struct Token: Sendable, Hashable, Identifiable {
        public let id: Int
        public let text: String
        public let kind: Kind

        public init(id: Int, text: String, kind: Kind) {
            self.id = id
            self.text = text
            self.kind = kind
        }
    }

    /// The candidate expressed as edits against the reference.
    public static func diff(reference: String, candidate: String) -> [Token] {
        let referenceWords = words(in: reference)
        let candidateWords = words(in: candidate)
        let referenceKeys = referenceWords.map(normalize)
        let candidateKeys = candidateWords.map(normalize)
        // Keep worst-case memory below ~8 MB. For long divergent transcripts,
        // preserve all words using a coarse diff instead of allocating N*M cells.
        if referenceKeys == candidateKeys {
            return candidateWords.enumerated().map { Token(id: $0.offset, text: $0.element, kind: .equal) }
        }
        if referenceKeys.count > 1_000_000 / max(candidateKeys.count, 1) {
            let removed = referenceWords.enumerated().map { Token(id: $0.offset, text: $0.element, kind: .deleted) }
            return removed + candidateWords.enumerated().map {
                Token(id: removed.count + $0.offset, text: $0.element, kind: .inserted)
            }
        }
        let table = lcsTable(referenceKeys, candidateKeys)

        var tokens: [Token] = []
        var refIndex = 0
        var candIndex = 0
        var nextID = 0
        func emit(_ text: String, _ kind: Kind) {
            tokens.append(Token(id: nextID, text: text, kind: kind))
            nextID += 1
        }

        while refIndex < referenceKeys.count || candIndex < candidateKeys.count {
            if refIndex < referenceKeys.count, candIndex < candidateKeys.count,
               referenceKeys[refIndex] == candidateKeys[candIndex] {
                emit(candidateWords[candIndex], .equal)
                refIndex += 1
                candIndex += 1
            } else if candIndex < candidateKeys.count,
                      refIndex == referenceKeys.count
                        || table[refIndex][candIndex + 1] >= table[refIndex + 1][candIndex] {
                emit(candidateWords[candIndex], .inserted)
                candIndex += 1
            } else {
                emit(referenceWords[refIndex], .deleted)
                refIndex += 1
            }
        }
        return tokens
    }

    /// The share of reference words the candidate did not reproduce, plus
    /// insertions, over the reference length — a word-error-rate-like figure
    /// for the summary row. `nil` when the reference is empty.
    public static func differenceRate(reference: String, candidate: String) -> Double? {
        let referenceCount = words(in: reference).count
        guard referenceCount > 0 else { return nil }
        let edits = diff(reference: reference, candidate: candidate).filter { $0.kind != .equal }.count
        return Double(edits) / Double(referenceCount)
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    static func normalize(_ word: String) -> String {
        let scalars = word.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        let normalized = String(String.UnicodeScalarView(scalars))
        // A token that is all punctuation (e.g. "—") keeps its text so it is
        // not treated as equal to every other punctuation token.
        return normalized.isEmpty ? word : normalized
    }

    /// `table[i][j]` is the LCS length of `lhs[i...]` and `rhs[j...]`.
    private static func lcsTable(_ lhs: [String], _ rhs: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for row in stride(from: lhs.count - 1, through: 0, by: -1) {
            for column in stride(from: rhs.count - 1, through: 0, by: -1) {
                table[row][column] = lhs[row] == rhs[column]
                    ? table[row + 1][column + 1] + 1
                    : max(table[row + 1][column], table[row][column + 1])
            }
        }
        return table
    }
}
