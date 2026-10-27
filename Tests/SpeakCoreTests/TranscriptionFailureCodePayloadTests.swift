import Foundation
import XCTest
@testable import SpeakCore

final class TranscriptionFailureCodePayloadTests: XCTestCase {
    func testLegacyErrorPayloadWithoutCodeRemainsReadable() throws {
        let legacy = Data("""
        {"status":"error","lastSnippet":"","wordCount":0,"duration":0,
         "provider":"Apple Speech","errorMessage":"Microphone access is off."}
        """.utf8)
        let state = try JSONDecoder().decode(TranscriptionActivityAttributes.ContentState.self, from: legacy)
        XCTAssertEqual(state.status, .error)
        XCTAssertEqual(state.errorMessage, "Microphone access is off.")
        XCTAssertNil(state.failureCode)
        XCTAssertEqual(state.completionOutcome, .ready)
    }

    func testLocalFailureCodeRoundTripsWithoutChangingExistingPayloadFields() throws {
        var state = TranscriptionActivityAttributes.ContentState(
            status: .error, provider: "Apple Speech", errorMessage: "Microphone access is off."
        )
        state.failureCode = "start_permission_microphone"
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TranscriptionActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded, state)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["failureCode"] as? String, "start_permission_microphone")
        XCTAssertEqual(fields["errorMessage"] as? String, "Microphone access is off.")
        XCTAssertEqual(fields["status"] as? String, "error")
    }
}
