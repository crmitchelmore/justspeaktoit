import LocalTranscriptionBenchmarkKit
import SpeakCore
import XCTest

final class TranscriptErrorRateTests: XCTestCase {
    func testWordErrorRate_normalizesCasePunctuationAndDiacritics() {
        XCTAssertEqual(
            TranscriptErrorRate.wordErrorRate(
                reference: "Café, HELLO!",
                hypothesis: "cafe hello"
            ),
            0
        )
    }

    func testWordErrorRate_countsSubstitutionInsertionAndDeletion() {
        XCTAssertEqual(
            TranscriptErrorRate.wordErrorRate(
                reference: "one two three four",
                hypothesis: "one too extra"
            ),
            0.75
        )
    }

    func testCharacterErrorRate_ignoresSpacesAndPunctuation() {
        XCTAssertEqual(
            TranscriptErrorRate.characterErrorRate(reference: "A B-C", hypothesis: "abc"),
            0
        )
    }

    func testAggregateRate_weightsByReferenceLength() {
        let measurements = [
            measurement(reference: "one", transcript: "wrong"),
            measurement(reference: "one two three", transcript: "one two three")
        ]

        XCTAssertEqual(TranscriptErrorRate.aggregateWordErrorRate(measurements), 0.25)
    }

    private func measurement(
        reference: String,
        transcript: String
    ) -> LocalTranscriptionBenchmarkMeasurement {
        LocalTranscriptionBenchmarkMeasurement(
            caseID: reference,
            iteration: 1,
            tags: [],
            referenceTranscript: reference,
            transcript: transcript,
            audioSeconds: 1,
            wallSeconds: 1,
            userCPUSeconds: 0,
            systemCPUSeconds: 0,
            peakResidentMemoryMB: 100
        )
    }
}
