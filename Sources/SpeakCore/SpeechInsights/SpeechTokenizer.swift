import Foundation
import NaturalLanguage

/// Word-level tokenization and lemmatization built on Apple's NaturalLanguage
/// framework. Everything runs on-device; no additional dependencies.
public enum SpeechTokenizer {
    /// One tokenized transcript: parallel arrays of the lowercased surface
    /// forms and their lemmas (falling back to the surface form when the
    /// lemmatizer has no answer).
    public struct TokenizedText: Sendable, Equatable {
        public let surfaceTokens: [String]
        public let lemmas: [String]

        public init(surfaceTokens: [String], lemmas: [String]) {
            self.surfaceTokens = surfaceTokens
            self.lemmas = lemmas
        }
    }

    /// Tokenizes `text` into lowercased word tokens with lemmas.
    /// Punctuation-only and whitespace tokens are dropped; tokens must contain
    /// at least one alphanumeric character.
    public static func tokenize(_ text: String) -> TokenizedText {
        guard !text.isEmpty else { return TokenizedText(surfaceTokens: [], lemmas: []) }

        var surfaces: [String] = []
        var lemmas: [String] = []
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation, .omitOther]
        ) { tag, range in
            let surface = text[range].lowercased()
            guard surface.rangeOfCharacter(from: .alphanumerics) != nil else { return true }
            surfaces.append(surface)
            let lemma = tag?.rawValue.lowercased()
            if let lemma, !lemma.isEmpty {
                lemmas.append(lemma)
            } else {
                lemmas.append(surface)
            }
            return true
        }
        return TokenizedText(surfaceTokens: surfaces, lemmas: lemmas)
    }

    /// Counts filler phrases over a surface-token stream.
    ///
    /// Matching is greedy and non-overlapping: phrases are tried longest first
    /// and a match consumes its tokens, so "sort of" never also counts "of",
    /// and "you know" wins over any single-word "you" filler entry.
    public static func countFillers(
        in surfaceTokens: [String],
        phrases: [[String]]
    ) -> [String: Int] {
        guard !phrases.isEmpty, !surfaceTokens.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        var index = 0
        while index < surfaceTokens.count {
            var matched = false
            for phrase in phrases where phrase.count <= surfaceTokens.count - index {
                var isMatch = true
                for (offset, word) in phrase.enumerated()
                where surfaceTokens[index + offset] != word {
                    isMatch = false
                    break
                }
                if isMatch {
                    counts[phrase.joined(separator: " "), default: 0] += 1
                    index += phrase.count
                    matched = true
                    break
                }
            }
            if !matched {
                index += 1
            }
        }
        return counts
    }

    /// Builds n-gram counts (space-joined) over a token stream.
    public static func ngramCounts(of tokens: [String], size: Int) -> [String: Int] {
        guard size > 0, tokens.count >= size else { return [:] }
        var counts: [String: Int] = [:]
        counts.reserveCapacity(tokens.count)
        for start in 0...(tokens.count - size) {
            let gram = tokens[start..<(start + size)].joined(separator: " ")
            counts[gram, default: 0] += 1
        }
        return counts
    }
}
