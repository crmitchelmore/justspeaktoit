import LocalTranscriptionBenchmarkKit
import XCTest

final class BenchmarkCorpusTests: XCTestCase {
    func testCorpusValidation_acceptsUniqueNonEmptyCases() throws {
        let corpus = LocalTranscriptionBenchmarkCorpus(cases: [
            LocalTranscriptionBenchmarkCase(
                id: "clean-short",
                audioPath: "audio/clean-short.wav",
                referenceTranscript: "hello world"
            )
        ])

        XCTAssertNoThrow(try corpus.validate())
    }

    func testCorpusValidation_rejectsDuplicateIdentifiers() {
        let benchmarkCase = LocalTranscriptionBenchmarkCase(
            id: "duplicate",
            audioPath: "audio.wav",
            referenceTranscript: "hello"
        )
        let corpus = LocalTranscriptionBenchmarkCorpus(cases: [benchmarkCase, benchmarkCase])

        XCTAssertThrowsError(try corpus.validate()) { error in
            XCTAssertEqual(error as? LocalTranscriptionBenchmarkError, .duplicateCaseIdentifiers)
        }
    }
}
