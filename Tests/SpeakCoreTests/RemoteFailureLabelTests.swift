import Foundation
import XCTest

@testable import SpeakCore

/// The recovery pass promises that nothing leaves the device. A provider error
/// carries the provider's raw HTTP response body in its message, so the rule
/// pinned here is that the label never contains the error's message.
final class RemoteFailureLabelTests: XCTestCase {
    private struct ProviderRejection: LocalizedError {
        let body: String
        var errorDescription: String? { "OpenRouter returned HTTP 500: \(body)" }
    }

    func testTheLabelNeverCarriesTheErrorsMessage() {
        let secret = "SECRET-RESPONSE-BODY-42"
        let label = RemoteFailureLabel.label(for: ProviderRejection(body: secret), status: 500)
        XCTAssertFalse(label.contains(secret))
        XCTAssertFalse(label.contains("OpenRouter returned"))
        XCTAssertTrue(label.contains("http=500"))
    }

    func testTheLabelNeverCarriesABridgedLocalizedDescription() {
        let error = NSError(
            domain: "TranscriptionDomain",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "SECRET-RESPONSE-BODY-42"]
        )
        let label = RemoteFailureLabel.label(for: error)
        XCTAssertFalse(label.contains("SECRET"))
        XCTAssertTrue(label.contains("domain=TranscriptionDomain"))
        XCTAssertTrue(label.contains("code=7"))
        XCTAssertFalse(label.contains("http="), "no status was recognised, so none is claimed")
    }

    func testCancellationIsItsOwnLabel() {
        XCTAssertEqual(RemoteFailureLabel.label(for: CancellationError()), "cancelled")
    }
}
