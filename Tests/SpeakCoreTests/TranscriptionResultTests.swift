import XCTest

@testable import SpeakCore

final class TranscriptionResultTests: XCTestCase {

    // MARK: - Construction

    func testTranscriptionResult_minimalConstruction() {
        let result = TranscriptionResult(
            text: "Hello world",
            segments: [],
            confidence: nil,
            duration: 1.5,
            modelIdentifier: "test-model",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.duration, 1.5)
        XCTAssertEqual(result.modelIdentifier, "test-model")
        XCTAssertNil(result.confidence)
        XCTAssertNil(result.cost)
    }

    func testTranscriptionResult_withAllFields() {
        let segment = TranscriptionSegment(
            startTime: 0.0,
            endTime: 1.0,
            text: "Hello",
            isFinal: true,
            confidence: 0.95
        )
        let costBreakdown = ChatCostBreakdown(
            inputTokens: 100, outputTokens: 50, totalCost: 0.001, currency: "USD"
        )
        let result = TranscriptionResult(
            text: "Hello",
            segments: [segment],
            confidence: 0.95,
            duration: 1.0,
            modelIdentifier: "model-1",
            cost: costBreakdown,
            rawPayload: "{\"text\":\"Hello\"}",
            debugInfo: nil
        )
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.confidence, 0.95)
        XCTAssertNotNil(result.cost)
        XCTAssertEqual(result.cost?.totalCost, 0.001)
    }

    // MARK: - Codable Round-Trip

    func testTranscriptionResult_codableRoundTrip() throws {
        let segment = TranscriptionSegment(
            startTime: 0.5,
            endTime: 2.0,
            text: "Test segment",
            isFinal: true,
            confidence: 0.88
        )
        let costBreakdown = ChatCostBreakdown(
            inputTokens: 200, outputTokens: 100, totalCost: 0.002, currency: "USD"
        )
        let original = TranscriptionResult(
            text: "Full transcription",
            segments: [segment],
            confidence: 0.9,
            duration: 2.5,
            modelIdentifier: "whisper-1",
            cost: costBreakdown,
            rawPayload: "{\"text\":\"Full transcription\"}",
            debugInfo: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)

        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.segments.first?.text, "Test segment")
        XCTAssertEqual(decoded.confidence, original.confidence)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.modelIdentifier, original.modelIdentifier)
        XCTAssertEqual(decoded.cost?.totalCost, 0.002)
    }

    func testTranscriptionResult_codableWithNilOptionals() throws {
        let original = TranscriptionResult(
            text: "Minimal",
            segments: [],
            confidence: nil,
            duration: 0.5,
            modelIdentifier: "m",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)

        XCTAssertEqual(decoded.text, "Minimal")
        XCTAssertNil(decoded.confidence)
        XCTAssertNil(decoded.cost)
        XCTAssertNil(decoded.rawPayload)
    }

    // MARK: - TranscriptionSegment

    func testSegment_defaultID_isUnique() {
        let seg1 = TranscriptionSegment(startTime: 0, endTime: 1, text: "A", isFinal: true)
        let seg2 = TranscriptionSegment(startTime: 1, endTime: 2, text: "B", isFinal: true)
        XCTAssertNotEqual(seg1.id, seg2.id)
    }

    func testSegment_hashable_conformance() {
        let seg = TranscriptionSegment(startTime: 0, endTime: 1, text: "A", isFinal: true)
        var set = Set<TranscriptionSegment>()
        set.insert(seg)
        set.insert(seg) // duplicate
        XCTAssertEqual(set.count, 1)
    }
}
