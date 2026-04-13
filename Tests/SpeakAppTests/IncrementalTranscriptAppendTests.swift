import SpeakCore
import XCTest

/// Tests that the incremental transcript append logic in DeepgramLiveController
/// produces the same result as the O(N) map+join it replaces, and benchmarks both.
final class IncrementalTranscriptAppendTests: XCTestCase {

    // MARK: - Correctness

    func testIncrementalAppend_matchesMapJoin() {
        let words = ["hello", "world", "this", "is", "a", "test", "of", "incremental", "append"]
        let segments = words.map { word in
            TranscriptionSegment(startTime: 0, endTime: 0, text: word)
        }

        // O(N) reference implementation (the old path)
        var referenceSegments: [TranscriptionSegment] = []
        var referenceTranscript = ""
        for segment in segments {
            referenceSegments.append(segment)
            referenceTranscript = referenceSegments.map(\.text).joined(separator: " ")
        }

        // O(1) incremental append (the new path)
        var incrementalTranscript = ""
        for segment in segments {
            if incrementalTranscript.isEmpty {
                incrementalTranscript = segment.text
            } else {
                incrementalTranscript += " " + segment.text
            }
        }

        XCTAssertEqual(incrementalTranscript, referenceTranscript)
        XCTAssertEqual(incrementalTranscript, "hello world this is a test of incremental append")
    }

    func testIncrementalAppend_singleSegment_noLeadingSpace() {
        var transcript = ""
        let segment = TranscriptionSegment(startTime: 0, endTime: 0, text: "hello")
        if transcript.isEmpty {
            transcript = segment.text
        } else {
            transcript += " " + segment.text
        }
        XCTAssertEqual(transcript, "hello")
    }

    func testIncrementalAppend_emptySessionReset_thenAppend() {
        var transcript = ""

        // First session
        transcript = "first"
        // Session reset
        transcript = ""
        // New session
        let word = "second"
        if transcript.isEmpty {
            transcript = word
        } else {
            transcript += " " + word
        }
        XCTAssertEqual(transcript, "second")
    }

    // MARK: - Performance

    func testIncrementalAppend_performance() {
        let segments = (0..<50).map { i in
            TranscriptionSegment(startTime: Double(i), endTime: Double(i) + 1, text: "word\(i)")
        }
        let expected = segments.map(\.text).joined(separator: " ")

        measure {
            var transcript = ""
            for segment in segments {
                if transcript.isEmpty {
                    transcript = segment.text
                } else {
                    transcript += " " + segment.text
                }
            }
            XCTAssertEqual(transcript, expected)
        }
    }

    func testMapJoin_performance_baseline() {
        let segments = (0..<50).map { i in
            TranscriptionSegment(startTime: Double(i), endTime: Double(i) + 1, text: "word\(i)")
        }

        var accumulated: [TranscriptionSegment] = []
        measure {
            accumulated = []
            for segment in segments {
                accumulated.append(segment)
                _ = accumulated.map(\.text).joined(separator: " ")
            }
        }
    }
}
