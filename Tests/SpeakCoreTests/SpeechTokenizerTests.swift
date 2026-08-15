import XCTest

@testable import SpeakCore

final class SpeechTokenizerTests: XCTestCase {
    // MARK: - Tokenization

    func testTokenize_lowercasesAndStripsPunctuation() {
        let result = SpeechTokenizer.tokenize("Hello, World! This is GREAT.")
        XCTAssertEqual(result.surfaceTokens, ["hello", "world", "this", "is", "great"])
        XCTAssertEqual(result.surfaceTokens.count, result.lemmas.count)
    }

    func testTokenize_emptyString() {
        let result = SpeechTokenizer.tokenize("")
        XCTAssertTrue(result.surfaceTokens.isEmpty)
        XCTAssertTrue(result.lemmas.isEmpty)
    }

    func testTokenize_whitespaceAndPunctuationOnly() {
        let result = SpeechTokenizer.tokenize("  ... !!! ---  \n\n")
        XCTAssertTrue(result.surfaceTokens.isEmpty)
    }

    func testTokenize_keepsNumericTokens() {
        let result = SpeechTokenizer.tokenize("I ate 2 apples")
        XCTAssertTrue(result.surfaceTokens.contains("2"))
        XCTAssertTrue(result.surfaceTokens.contains("apples"))
    }

    func testTokenize_lemmaFallsBackToSurfaceForUnknownWords() {
        let result = SpeechTokenizer.tokenize("blorptastic")
        XCTAssertEqual(result.surfaceTokens, ["blorptastic"])
        XCTAssertEqual(result.lemmas, ["blorptastic"])
    }

    func testTokenize_foldsPluralsToLemmaWithSentenceContext() {
        let result = SpeechTokenizer.tokenize("The cats and the cat were sleeping.")
        let catLemmas = result.lemmas.filter { $0 == "cat" }
        XCTAssertEqual(catLemmas.count, 2, "both 'cats' and 'cat' should lemmatize to 'cat'")
    }

    func testTokenize_multilineTranscript() {
        let result = SpeechTokenizer.tokenize("alpha beta\ngamma\n\ndelta")
        XCTAssertEqual(result.surfaceTokens, ["alpha", "beta", "gamma", "delta"])
    }

    // MARK: - Filler counting

    private let defaultFillers = SpeechInsightsConfiguration.default.fillerTokenSequences

    func testCountFillers_singleWordFillers() {
        let tokens = SpeechTokenizer.tokenize("um so um I was um thinking").surfaceTokens
        let counts = SpeechTokenizer.countFillers(in: tokens, phrases: defaultFillers)
        XCTAssertEqual(counts["um"], 3)
    }

    func testCountFillers_multiWordPhrase() {
        let tokens = ["it", "was", "sort", "of", "strange", "you", "know"]
        let counts = SpeechTokenizer.countFillers(in: tokens, phrases: defaultFillers)
        XCTAssertEqual(counts["sort of"], 1)
        XCTAssertEqual(counts["you know"], 1)
    }

    func testCountFillers_matchesAreNonOverlapping() {
        // "sort of sort of" must count exactly twice, and the consumed "of"
        // must not seed a second overlapping match.
        let tokens = ["sort", "of", "sort", "of"]
        let counts = SpeechTokenizer.countFillers(in: tokens, phrases: defaultFillers)
        XCTAssertEqual(counts["sort of"], 2)
        XCTAssertEqual(counts.values.reduce(0, +), 2)
    }

    func testCountFillers_prefersLongestPhrase() {
        let config = SpeechInsightsConfiguration(fillerPhrases: ["you know what", "you know"])
        let tokens = ["you", "know", "what", "then", "you", "know"]
        let counts = SpeechTokenizer.countFillers(in: tokens, phrases: config.fillerTokenSequences)
        XCTAssertEqual(counts["you know what"], 1)
        XCTAssertEqual(counts["you know"], 1)
    }

    func testCountFillers_noMatches() {
        let tokens = ["completely", "clean", "sentence"]
        let counts = SpeechTokenizer.countFillers(in: tokens, phrases: defaultFillers)
        XCTAssertTrue(counts.isEmpty)
    }

    func testCountFillers_emptyInputs() {
        XCTAssertTrue(SpeechTokenizer.countFillers(in: [], phrases: defaultFillers).isEmpty)
        XCTAssertTrue(SpeechTokenizer.countFillers(in: ["um"], phrases: []).isEmpty)
    }

    func testCountFillers_isCaseInsensitiveViaTokenizer() {
        let tokens = SpeechTokenizer.tokenize("Um, UM! uM.").surfaceTokens
        let counts = SpeechTokenizer.countFillers(in: tokens, phrases: defaultFillers)
        XCTAssertEqual(counts["um"], 3)
    }

    // MARK: - Filler matches (consumed token ranges)

    func testMatchFillers_multiWordPhraseConsumesEveryToken() {
        let tokens = ["it", "was", "sort", "of", "strange", "you", "know"]
        let matches = SpeechTokenizer.matchFillers(in: tokens, phrases: defaultFillers)
        XCTAssertEqual(matches.counts["sort of"], 1)
        XCTAssertEqual(matches.counts["you know"], 1)
        XCTAssertEqual(matches.consumedTokenIndices, [2, 3, 5, 6])
    }

    func testMatchFillers_singleWordFillerConsumesItsToken() {
        let tokens = ["um", "hello", "um"]
        let matches = SpeechTokenizer.matchFillers(in: tokens, phrases: defaultFillers)
        XCTAssertEqual(matches.counts["um"], 2)
        XCTAssertEqual(matches.consumedTokenIndices, [0, 2])
    }

    func testMatchFillers_repeatedMultiWordPhraseConsumesAllSpans() {
        let tokens = ["sort", "of", "sort", "of", "planning"]
        let matches = SpeechTokenizer.matchFillers(in: tokens, phrases: defaultFillers)
        XCTAssertEqual(matches.counts["sort of"], 2)
        XCTAssertEqual(matches.consumedTokenIndices, [0, 1, 2, 3])
        XCTAssertFalse(matches.consumedTokenIndices.contains(4))
    }

    func testMatchFillers_longestPhraseWinsAndConsumedSpansDoNotOverlap() {
        let config = SpeechInsightsConfiguration(fillerPhrases: ["you know what", "you know"])
        let tokens = ["you", "know", "what", "then", "you", "know"]
        let matches = SpeechTokenizer.matchFillers(in: tokens, phrases: config.fillerTokenSequences)
        XCTAssertEqual(matches.counts["you know what"], 1)
        XCTAssertEqual(matches.counts["you know"], 1)
        XCTAssertEqual(matches.consumedTokenIndices, [0, 1, 2, 4, 5])
    }

    func testMatchFillers_noMatchesConsumesNothing() {
        let matches = SpeechTokenizer.matchFillers(
            in: ["completely", "clean", "sentence"],
            phrases: defaultFillers
        )
        XCTAssertTrue(matches.counts.isEmpty)
        XCTAssertTrue(matches.consumedTokenIndices.isEmpty)
    }

    func testMatchFillers_emptyInputs() {
        XCTAssertEqual(
            SpeechTokenizer.matchFillers(in: [], phrases: defaultFillers),
            SpeechTokenizer.FillerMatches(counts: [:], consumedTokenIndices: [])
        )
        XCTAssertEqual(
            SpeechTokenizer.matchFillers(in: ["um"], phrases: []),
            SpeechTokenizer.FillerMatches(counts: [:], consumedTokenIndices: [])
        )
    }

    func testCountFillers_matchesMatchFillersCounts() {
        let tokens = ["um", "it", "was", "sort", "of", "fine", "you", "know"]
        XCTAssertEqual(
            SpeechTokenizer.countFillers(in: tokens, phrases: defaultFillers),
            SpeechTokenizer.matchFillers(in: tokens, phrases: defaultFillers).counts
        )
    }

    // MARK: - N-grams

    func testNgramCounts_bigrams() {
        let counts = SpeechTokenizer.ngramCounts(of: ["a", "b", "a", "b"], size: 2)
        XCTAssertEqual(counts["a b"], 2)
        XCTAssertEqual(counts["b a"], 1)
        XCTAssertEqual(counts.values.reduce(0, +), 3)
    }

    func testNgramCounts_trigrams() {
        let counts = SpeechTokenizer.ngramCounts(of: ["x", "y", "z", "x"], size: 3)
        XCTAssertEqual(counts["x y z"], 1)
        XCTAssertEqual(counts["y z x"], 1)
        XCTAssertEqual(counts.count, 2)
    }

    func testNgramCounts_inputShorterThanSize() {
        XCTAssertTrue(SpeechTokenizer.ngramCounts(of: ["only", "two"], size: 3).isEmpty)
        XCTAssertTrue(SpeechTokenizer.ngramCounts(of: [], size: 2).isEmpty)
    }

    func testNgramCounts_sizeOfOneMatchesTokenCounts() {
        let counts = SpeechTokenizer.ngramCounts(of: ["a", "a", "b"], size: 1)
        XCTAssertEqual(counts["a"], 2)
        XCTAssertEqual(counts["b"], 1)
    }
}
