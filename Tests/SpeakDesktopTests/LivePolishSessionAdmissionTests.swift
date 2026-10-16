import Foundation
import SpeakCore
import XCTest

final class LivePolishSessionAdmissionTests: XCTestCase {
    func testSubthresholdAppend_RetiresVisibleSuccessWithoutSchedulingAnotherRequest() async {
        let clock = PolishClock()
        let client = PolishClient()
        let updated = expectation(description: "first clean")
        let session = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "model",
            sleep: { try await clock.sleep($0) }, onChange: { if $0.succeeded { updated.fulfill() } },
            complete: { try await client.complete($0) }
        )
        session.submit("base", immediately: true)
        _ = await client.request(0)
        _ = await clock.pending(0)
        await client.succeed(0, "Base.")
        await fulfillment(of: [updated], timeout: 2)
        let before = await clock.count
        session.submit("base1")
        XCTAssertEqual(session.snapshot().input, "base1")
        XCTAssertNil(session.snapshot().text)
        let after = await clock.count
        XCTAssertEqual(after, before)
        session.submit("base2")
        let changed = await clock.pending(before)
        XCTAssertEqual(changed, .milliseconds(500), "Same-length edits in a subthreshold suffix still refresh")
        session.cancel()
        await clock.releaseAll()
    }

    func testPausedLane_RejectsPartialAndBoundaryUpdatesButAllowsOneAuthoritativeFinal() async {
        let client = PolishClient()
        let session = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "model",
            complete: { try await client.complete($0) }
        )
        session.pause()
        session.submit("after stop", immediately: true)
        let count = await client.count
        XCTAssertEqual(count, 0)
        let finishing = Task { await session.finish("authoritative") }
        let request = await client.request(0)
        XCTAssertEqual(request, "authoritative")
        await client.succeed(0, "Authoritative.")
        let result = await finishing.value
        session.submit("after completion", immediately: true)
        XCTAssertEqual(session.snapshot(), result)
        let requests = await client.count
        XCTAssertEqual(requests, 1)
    }

    func testMultipleFinishWaiters_ShareOneRequestAndOneFinalIdentity() async {
        let client = PolishClient()
        let session = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "model",
            complete: { try await client.complete($0) }
        )
        let first = Task { await session.finish("authoritative") }
        _ = await client.request(0)
        let second = Task { await session.finish("authoritative") }
        await client.succeed(0, "Authoritative.")
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, secondResult)
        let count = await client.count
        XCTAssertEqual(count, 1)
    }

    func testInvalidTimingConfiguration_IsAnExplicitFailureBeforeClientAdmission() async {
        let client = PolishClient()
        let session = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish, debounceMilliseconds: -1),
            modelIdentifier: "model", complete: { try await client.complete($0) }
        )
        let result = await session.finish("raw")
        XCTAssertEqual(result.failure, LivePolishError.invalidConfiguration.localizedDescription)
        XCTAssertNil(result.text)
        let count = await client.count
        XCTAssertEqual(count, 0)
    }
}
