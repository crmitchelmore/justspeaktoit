#if canImport(Darwin)
import Foundation
import XCTest

@testable import SpeakCore

final class OpenRouterAudioCancellationLatchTests: XCTestCase {
    func testCancellationBeforeTaskRegistration_CancelsOnlyLateRegisteredTask() throws {
        try assertOwnedCancellation(cancelBeforeRegistration: true)
    }

    func testCancellationAfterTaskRegistration_CancelsOnlyRegisteredTask() throws {
        try assertOwnedCancellation(cancelBeforeRegistration: false)
    }

    private func assertOwnedCancellation(cancelBeforeRegistration: Bool) throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://speech-latch.invalid"))
        // Never resume either task: this directly exercises the latch without transport or credentials.
        let owned = session.dataTask(with: url)
        let unrelated = session.dataTask(with: url)
        XCTAssertEqual(owned.state, .suspended)
        XCTAssertEqual(unrelated.state, .suspended)
        let policy = OpenRouterAudioRedirectPolicy()
        if cancelBeforeRegistration { policy.cancel() }
        policy.urlSession(session, didCreateTask: owned)
        if !cancelBeforeRegistration { policy.cancel() }
        XCTAssertTrue([URLSessionTask.State.canceling, .completed].contains(owned.state))
        XCTAssertEqual(unrelated.state, .suspended, "Cancellation belongs to the registered task only")
    }
}
#endif
