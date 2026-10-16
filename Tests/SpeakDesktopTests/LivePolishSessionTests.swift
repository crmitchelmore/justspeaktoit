import Foundation
import SpeakCore
import XCTest

final class LivePolishSessionTests: XCTestCase {
    func testInstantAndSilentFinal_NeverInvokeClientOrScheduler() async {
        let client = PolishClient()
        let clock = PolishClock()
        let instant = LivePolishSession(
            recordingID: UUID(), preferences: .init(), modelIdentifier: "unused",
            sleep: { try await clock.sleep($0) }, complete: { try await client.complete($0) }
        )
        instant.submit("No cleanup")
        let raw = await instant.finish("No cleanup")
        XCTAssertFalse(raw.succeeded)
        XCTAssertNil(raw.failure)
        let silent = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "unused",
            sleep: { try await clock.sleep($0) }, complete: { try await client.complete($0) }
        )
        silent.submit("")
        let empty = await silent.finish(" \n ")
        XCTAssertFalse(empty.succeeded)
        XCTAssertNil(empty.failure)
        let requests = await client.count
        XCTAssertEqual(requests, 0)
    }

    func testDebounceLatestWins_OnlyLatestSnapshotIsAdmittedAfter500Milliseconds() async {
        let clock = PolishClock()
        let client = PolishClient()
        let changed = expectation(description: "latest result")
        let session = makeSession(clock: clock, client: client) { result in
            if result.text == "Latest." { changed.fulfill() }
        }
        session.submit("old")
        let firstDelay = await clock.pending(0)
        XCTAssertEqual(firstDelay, .milliseconds(500))
        session.submit("latest")
        _ = await clock.pending(1)
        await clock.advance(0)
        await clock.advance(1)
        let request = await client.request(0)
        XCTAssertEqual(request, "latest")
        await client.succeed(0, "Latest.")
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(session.snapshot().input, "latest")
        let count = await client.count
        XCTAssertEqual(count, 1)
        session.cancel()
        await clock.releaseAll()
    }

    func testFinalBoundary_BypassesDebounceAndReusesExactSuccessfulInput() async {
        let client = PolishClient()
        let clock = PolishClock()
        let changed = expectation(description: "boundary result")
        let session = makeSession(clock: clock, client: client) { result in
            if result.text == "Boundary." { changed.fulfill() }
        }
        session.submit("boundary", immediately: true)
        let request = await client.request(0)
        XCTAssertEqual(request, "boundary")
        await client.succeed(0, "Boundary.")
        await fulfillment(of: [changed], timeout: 2)
        session.pause()
        let result = await session.finish("boundary")
        XCTAssertEqual(result.text, "Boundary.")
        let count = await client.count
        XCTAssertEqual(count, 1, "An exact successful full transcript is not polished twice")
        await clock.releaseAll()
    }

    func testSameLengthEditAndRetraction_RetireOldCompletionsIncludingEmptyRetraction() async {
        let client = PolishClient()
        let clock = PolishClock()
        let session = makeSession(clock: clock, client: client)
        session.submit("one", immediately: true)
        _ = await client.request(0)
        session.submit("two", immediately: true)
        let edited = await client.request(1)
        XCTAssertEqual(edited, "two")
        session.submit("")
        await client.succeed(1, "Two.")
        await client.succeed(0, "One.")
        let result = await session.finish("")
        XCTAssertEqual(result.input, "")
        XCTAssertNil(result.text)
        XCTAssertNil(result.failure)
        await clock.releaseAll()
    }

    func testOutOfOrderCompletion_CannotReplaceNewerFinalOrAnotherRecording() async {
        let client = PolishClient()
        let clock = PolishClock()
        let old = makeSession(clock: clock, client: client)
        old.submit("old", immediately: true)
        _ = await client.request(0)
        old.cancel()
        let next = makeSession(clock: clock, client: client)
        XCTAssertNotEqual(old.recordingID, next.recordingID)
        let final = Task { await next.finish("new authoritative") }
        _ = await client.request(1)
        await client.succeed(1, "New authoritative.")
        let result = await final.value
        await client.succeed(0, "OLD")
        XCTAssertEqual(result.text, "New authoritative.")
        XCTAssertNil(old.snapshot().text)
        XCTAssertEqual(next.snapshot(), result)
        await clock.releaseAll()
    }

    func testStopFinalization_CancelsPartialAndPolishesAuthoritativeFullReplacement() async {
        let client = PolishClient()
        let clock = PolishClock()
        let session = makeSession(clock: clock, client: client)
        session.submit("partial", immediately: true)
        _ = await client.request(0)
        session.pause()
        let final = Task { await session.finish("authoritative") }
        let request = await client.request(1)
        XCTAssertEqual(request, "authoritative")
        await client.succeed(1, "Authoritative.")
        let result = await final.value
        await client.succeed(0, "Stale partial.")
        XCTAssertEqual(result.input, "authoritative")
        XCTAssertEqual(result.text, "Authoritative.")
        XCTAssertEqual(session.snapshot(), result)
        await clock.releaseAll()
    }

    func testCancelDuringFinalization_WakesWaiterWithoutWaitingForNonCooperativeClient() async {
        let client = PolishClient()
        let clock = PolishClock()
        let session = makeSession(clock: clock, client: client)
        let final = Task { await session.finish("raw") }
        _ = await client.request(0)
        final.cancel()
        let result = await final.value
        XCTAssertEqual(result.input, "raw")
        XCTAssertNil(result.text)
        XCTAssertEqual(result.failure, LivePolishError.cancelled.localizedDescription)
        await client.succeed(0, "Too late.")
        XCTAssertNil(session.snapshot().text)
        await clock.releaseAll()
    }

    func testTimeoutAndFailure_NeverReportRawOrBlankAsPolishedSuccess() async {
        let client = PolishClient()
        let clock = PolishClock()
        let session = makeSession(clock: clock, client: client)
        let final = Task { await session.finish("raw") }
        _ = await client.request(0)
        let duration = await clock.pending(0)
        XCTAssertEqual(duration, LivePolishPolicy.requestTimeout)
        await clock.advance(0)
        let result = await final.value
        XCTAssertNil(result.text)
        XCTAssertEqual(result.failure, LivePolishError.timedOut.localizedDescription)
        await client.succeed(0, "Late.")
        XCTAssertFalse(session.snapshot().succeeded)
        for output in ["", " \n "] {
            let invalid = LivePolishSession(
                recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "model",
                complete: { _ in output }
            )
            let invalidResult = await invalid.finish("raw")
            XCTAssertEqual(invalidResult.failure, LivePolishError.invalidResponse.localizedDescription)
            XCTAssertFalse(invalidResult.succeeded)
        }
        let failing = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "model",
            complete: { _ in throw PolishFixtureError.failed }
        )
        let failed = await failing.finish("raw")
        XCTAssertEqual(failed.failure, "Injected cleanup request failed.")
        XCTAssertNil(failed.text)
        await clock.releaseAll()
    }

    private func makeSession(
        clock: PolishClock, client: PolishClient,
        onChange: @escaping @Sendable (LivePolishSession.Result) -> Void = { _ in }
    ) -> LivePolishSession {
        LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: "captured-model",
            sleep: { try await clock.sleep($0) }, onChange: onChange, complete: { try await client.complete($0) }
        )
    }
}
