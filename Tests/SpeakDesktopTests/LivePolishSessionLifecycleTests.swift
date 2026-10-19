import Foundation
import SpeakCore
import XCTest

final class LivePolishSessionLifecycleTests: XCTestCase {
    func testImmediateResults_DefaultClockRetiresWithoutCancellingDeliveryOrCorruptingHistory() async throws {
        for fails in [false, true] {
            for index in 0..<32 {
                let input = "raw-\(index)"
                let session = LivePolishSession(
                    recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "model",
                    onChange: { _ in
                        XCTAssertFalse(Task.isCancelled, "Normal delivery must not cancel its own producer")
                    },
                    complete: { text in
                        if fails { throw PolishFixtureError.failed }
                        return text + "."
                    }
                )
                let outcome = await session.finish(input)
                XCTAssertEqual(outcome.input, input)
                XCTAssertEqual(outcome.succeeded, !fails)
                XCTAssertEqual(outcome.text, fails ? nil : input + ".")
                XCTAssertEqual(outcome.failure, fails ? PolishFixtureError.failed.localizedDescription : nil)
                let encoded = try JSONEncoder().encode(outcome)
                XCTAssertEqual(try JSONDecoder().decode(LivePolishSession.Result.self, from: encoded), outcome)
            }
        }
    }

    func testTimeout_DeliversUncancelledButCancelsAndFencesTheProvider() async {
        let clock = PolishClock()
        let client = PolishClient()
        let providerReturned = expectation(description: "cancelled provider returned")
        let session = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "model",
            sleep: { try await clock.sleep($0) },
            onChange: { _ in
                XCTAssertFalse(Task.isCancelled, "Timeout delivery must not cancel its own timer")
            },
            complete: { text in
                let output = try await client.complete(text)
                XCTAssertTrue(Task.isCancelled, "The timed-out provider must still be cancelled")
                providerReturned.fulfill()
                return output
            }
        )
        let finishing = Task { await session.finish("raw") }
        _ = await client.request(0)
        let duration = await clock.pending(0)
        XCTAssertEqual(duration, LivePolishPolicy.requestTimeout)
        await clock.advance(0)
        let outcome = await finishing.value
        XCTAssertEqual(outcome.failure, LivePolishError.timedOut.localizedDescription)
        XCTAssertNil(outcome.text)
        await client.succeed(0, "Too late.")
        await fulfillment(of: [providerReturned], timeout: 2)
        XCTAssertEqual(session.snapshot(), outcome)
        await clock.releaseAll()
    }
}
