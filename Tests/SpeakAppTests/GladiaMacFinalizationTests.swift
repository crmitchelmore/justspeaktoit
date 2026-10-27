import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakApp

final class GladiaMacFinalizationTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testStopWaitsPastAcknowledgementAndAllFinalsUntilEndSession() async throws {
        let fixture = GladiaMacFixture()
        try await start(fixture)
        let socket = try XCTUnwrap(fixture.factory.socket(0))
        socket.emit(Self.transcript("First.", final: true, confidence: 0.9))
        fixture.client.sendAudio(Data([1, 0, 2, 0]))
        socket.completeSend()
        let stopSent = expectation(description: "Owned stop_recording sent")
        socket.onStop = { stopSent.fulfill() }
        let outcome = GladiaMacOutcome()
        let settled = expectation(description: "Terminal wait settled")
        let pending = Task { outcome.store(await fixture.client.finishAndWait(timeout: 5)); settled.fulfill() }
        defer { pending.cancel(); fixture.client.stop() }
        await fulfillment(of: [stopSent], timeout: 2)
        XCTAssertEqual(socket.sent, [.binary(Data([1, 0, 2, 0])), .text(#"{"type":"stop_recording"}"#)])
        socket.emit(#"{"type":"acknowledgment","data":{"type":"stop_recording"}}"#)
        socket.emit(Self.transcript("Second.", final: true, confidence: 0.8))
        socket.emit(Self.transcript("Third.", final: true, confidence: 0.7))
        XCTAssertNil(outcome.value, "Acknowledgement and the first final are not end_session")
        socket.emit(#"{"type":"end_session","data":{"session_id":"synthetic"}}"#)
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.finals.map(\.text), ["First.", "Second.", "Third."])
        XCTAssertEqual(result.finals.compactMap(\.confidence), [0.9, 0.8, 0.7])
        XCTAssertNil(result.interim)
        XCTAssertNil(result.error)
        XCTAssertEqual(socket.cancels, 1)
        // A late send completion cannot turn a terminal snapshot into failure.
        socket.completeSend(error: URLError(.networkConnectionLost))
        XCTAssertNil(fixture.client.snapshot.error)
        XCTAssertEqual(fixture.errors.count, 0)
    }

    func testStopSendFailureKeepsTrailingFinalConfidenceAndDraftBeforeReturning() async throws {
        let fixture = GladiaMacFixture()
        try await start(fixture)
        let socket = try XCTUnwrap(fixture.factory.socket(0))
        socket.emit(Self.transcript("Confirmed.", final: true, confidence: 0.9))
        let stopSent = expectation(description: "Stop send held")
        socket.onStop = { stopSent.fulfill() }
        let outcome = GladiaMacOutcome()
        let failed = expectation(description: "Failure callback published")
        fixture.onError = { _ in
            XCTAssertNotNil(fixture.client.snapshot.error)
            XCTAssertNil(outcome.value, "Failure must precede finish settlement")
            failed.fulfill()
        }
        let settled = expectation(description: "Failed finish settled")
        let pending = Task {
            outcome.store(await fixture.client.finishAndWait(timeout: 5))
            settled.fulfill()
        }
        defer { pending.cancel(); fixture.client.stop() }
        await fulfillment(of: [stopSent], timeout: 2)
        socket.emit(Self.transcript("New tail.", final: true, confidence: 0.75))
        socket.emit(Self.transcript("retained draft", final: false, confidence: 0.5))
        socket.completeSend(error: URLError(.networkConnectionLost))
        await fulfillment(of: [failed, settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.finals.map(\.text), ["Confirmed.", "New tail."])
        XCTAssertEqual(result.finals.compactMap(\.confidence), [0.9, 0.75])
        XCTAssertEqual(result.interim?.text, "retained draft")
        XCTAssertNotNil(result.error)
        XCTAssertNotNil(fixture.client.takeFailureForReporting())
        XCTAssertNil(fixture.client.takeFailureForReporting())
        XCTAssertEqual(fixture.errors.count, 1)
    }

    func testDeadlineIsExistingBoundAndRetainsInterimWithoutClaimingEndSession() async throws {
        let fixture = GladiaMacFixture()
        try await start(fixture)
        let socket = try XCTUnwrap(fixture.factory.socket(0))
        socket.emit(Self.transcript("draft", final: false, confidence: 0.6))
        let stopSent = expectation(description: "Stop sent before deadline")
        socket.onStop = { stopSent.fulfill() }
        let outcome = GladiaMacOutcome()
        let settled = expectation(description: "Deadline settled")
        let pending = Task {
            outcome.store(await fixture.client.finishAndWait(timeout: 5))
            settled.fulfill()
        }
        defer { pending.cancel(); fixture.client.stop() }
        await fulfillment(of: [stopSent], timeout: 2)
        XCTAssertEqual(fixture.clock.delays, [5])
        fixture.clock.fire()
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.interim?.text, "draft")
        XCTAssertNotNil(result.error)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testOldEndSendAndDeadlineCannotSettleOrMutateRestartedRun() async throws {
        let fixture = GladiaMacFixture()
        try await start(fixture)
        let old = try XCTUnwrap(fixture.factory.socket(0))
        old.emit(Self.transcript("Old.", final: true, confidence: 0.7))
        let oldStop = expectation(description: "Old stop sent")
        old.onStop = { oldStop.fulfill() }
        let outcome = GladiaMacOutcome()
        let settled = expectation(description: "Old waiter cancelled on restart")
        let pending = Task {
            outcome.store(await fixture.client.finishAndWait(timeout: 5))
            settled.fulfill()
        }
        defer { pending.cancel(); fixture.client.stop() }
        await fulfillment(of: [oldStop], timeout: 2)
        try await start(fixture, index: 1)
        let current = try XCTUnwrap(fixture.factory.socket(1))
        current.emit(Self.transcript("Current.", final: true, confidence: 0.95))
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertTrue(try XCTUnwrap(outcome.value).error is CancellationError)
        old.emit(#"{"type":"end_session"}"#)
        old.completeSend(error: URLError(.networkConnectionLost))
        fixture.clock.fire()
        XCTAssertEqual(fixture.client.snapshot.finals.map(\.text), ["Current."])
        XCTAssertNil(fixture.client.snapshot.error)
        XCTAssertEqual(current.cancels, 0)
        XCTAssertEqual(fixture.errors.count, 0)
    }

    func testFinishCallersShareOneStopAndObserveExplicitCancellation() async throws {
        let fixture = GladiaMacFixture()
        try await start(fixture)
        let socket = try XCTUnwrap(fixture.factory.socket(0))
        let stopSent = expectation(description: "One shared stop")
        socket.onStop = { stopSent.fulfill() }
        let settled = expectation(description: "Both waiters settled")
        settled.expectedFulfillmentCount = 2
        let first = GladiaMacOutcome(), second = GladiaMacOutcome()
        let taskOne = Task { first.store(await fixture.client.finishAndWait(timeout: 5)); settled.fulfill() }
        let taskTwo = Task { second.store(await fixture.client.finishAndWait(timeout: 5)); settled.fulfill() }
        defer { taskOne.cancel(); taskTwo.cancel(); fixture.client.stop() }
        await fulfillment(of: [stopSent], timeout: 2)
        fixture.client.stop()
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertTrue(try XCTUnwrap(first.value).error is CancellationError)
        XCTAssertTrue(try XCTUnwrap(second.value).error is CancellationError)
        XCTAssertEqual(socket.sent, [.text(#"{"type":"stop_recording"}"#)])
        XCTAssertEqual(socket.cancels, 1)
    }

    func testFinishJoiningHeldErrorReportWaitsUntilTheReportReturns() async throws {
        let fixture = GladiaMacFixture()
        try await start(fixture)
        let socket = try XCTUnwrap(fixture.factory.socket(0))
        let stopSent = expectation(description: "Stop send held")
        socket.onStop = { stopSent.fulfill() }
        let reportEntered = expectation(description: "Error report entered")
        let reportReturned = expectation(description: "Error report returned")
        let reportGate = GladiaMacHold()
        fixture.onError = { _ in
            reportEntered.fulfill()
            XCTAssertTrue(reportGate.wait(), "Owned report hold is bounded")
            reportReturned.fulfill()
        }
        let secondRegistered = expectation(description: "Second finish joined the held report")
        let count = GladiaMacCount()
        fixture.factory.onFinishRegistered = { if count.increment() == 2 { secondRegistered.fulfill() } }
        let first = GladiaMacOutcome(), second = GladiaMacOutcome()
        let settled = expectation(description: "Both finish callers settled after report")
        settled.expectedFulfillmentCount = 2
        let taskOne = Task { first.store(await fixture.client.finishAndWait(timeout: 5)); settled.fulfill() }
        defer { taskOne.cancel(); reportGate.release(); fixture.client.stop() }
        await fulfillment(of: [stopSent], timeout: 2)
        DispatchQueue.global().async { socket.completeSend(error: URLError(.networkConnectionLost)) }
        await fulfillment(of: [reportEntered], timeout: 2)
        let taskTwo = Task { second.store(await fixture.client.finishAndWait(timeout: 5)); settled.fulfill() }
        defer { taskTwo.cancel() }
        await fulfillment(of: [secondRegistered], timeout: 2)
        XCTAssertNil(first.value)
        XCTAssertNil(second.value, "A closed run is still reporting its failure")
        reportGate.release()
        await fulfillment(of: [reportReturned, settled], timeout: 2)
        XCTAssertNotNil(try XCTUnwrap(first.value).error)
        XCTAssertNotNil(try XCTUnwrap(second.value).error)
        XCTAssertEqual(fixture.errors.count, 1)
    }

    func testEndSessionBeforeStopHandoffFailsAndDoesNotSendClaimedStop() async throws {
        let fixture = GladiaMacFixture()
        try await start(fixture)
        let socket = try XCTUnwrap(fixture.factory.socket(0))
        let claimed = expectation(description: "Stop claimed before socket handoff")
        let gate = GladiaMacHold()
        fixture.factory.beforeHandoff = {
            claimed.fulfill()
            XCTAssertTrue(gate.wait(), "Owned handoff hold is bounded")
        }
        let outcome = GladiaMacOutcome()
        let settled = expectation(description: "Premature end settled with failure")
        let pending = Task {
            outcome.store(await fixture.client.finishAndWait(timeout: 5))
            settled.fulfill()
        }
        defer { gate.release(); pending.cancel(); fixture.client.stop() }
        await fulfillment(of: [claimed], timeout: 2)
        socket.emit(#"{"type":"end_session"}"#)
        XCTAssertNotNil(fixture.client.snapshot.error)
        XCTAssertTrue(socket.sent.isEmpty)
        gate.release()
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertNotNil(try XCTUnwrap(outcome.value).error)
        XCTAssertTrue(socket.sent.isEmpty, "Retired claim must not reach the socket")
        XCTAssertEqual(fixture.errors.count, 1)
        XCTAssertEqual(socket.cancels, 1)
    }

    func testStopBeforeInitReturnsDrainsBufferedPCMThenWaitsForEndSession() async throws {
        let fixture = GladiaMacFixture()
        let initEntered = expectation(description: "Init request held")
        let initGate = GladiaMacHold()
        installInitStub {
            initEntered.fulfill()
            XCTAssertTrue(initGate.wait(), "Owned init hold is bounded")
        }
        let resumed = expectation(description: "Delayed socket resumed")
        let stopSent = expectation(description: "Delayed stop sent")
        let audioSent = expectation(description: "Buffered PCM handed to delayed socket")
        fixture.factory.onAudio = { audioSent.fulfill() }
        fixture.factory.onResume = { _ in resumed.fulfill() }
        fixture.factory.onStop = { stopSent.fulfill() }
        fixture.client.start(onTranscript: { _ in }, onError: { [weak fixture] error in fixture?.record(error) })
        defer { initGate.release(); fixture.client.stop() }
        await fulfillment(of: [initEntered], timeout: 2)
        fixture.client.sendAudio(Data([1, 0, 2, 0]))
        let registered = expectation(description: "Finish waiter installed before init completes")
        fixture.factory.onFinishRegistered = { registered.fulfill() }
        let outcome = GladiaMacOutcome()
        let settled = expectation(description: "Delayed init finish settled")
        let pending = Task {
            outcome.store(await fixture.client.finishAndWait(timeout: 5))
            settled.fulfill()
        }
        defer { pending.cancel() }
        await fulfillment(of: [registered], timeout: 2)
        XCTAssertNil(fixture.factory.socket(0))
        initGate.release()
        await fulfillment(of: [resumed, audioSent], timeout: 2)
        let socket = try XCTUnwrap(fixture.factory.socket(0))
        XCTAssertEqual(socket.sent, [.binary(Data([1, 0, 2, 0]))])
        socket.completeSend()
        await fulfillment(of: [stopSent], timeout: 2)
        socket.emit(Self.transcript("Opening and ending words.", final: true, confidence: 0.85))
        XCTAssertNil(outcome.value)
        socket.emit(#"{"type":"end_session"}"#)
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.finals.map(\.text), ["Opening and ending words."])
        XCTAssertNil(result.error)
        XCTAssertEqual(socket.sent, [.binary(Data([1, 0, 2, 0])), .text(#"{"type":"stop_recording"}"#)])
    }

}

private extension GladiaMacFinalizationTests {
    func start(_ fixture: GladiaMacFixture, index: Int = 0) async throws {
        installInitStub()
        let resumed = expectation(description: "Owned mock socket resumed")
        fixture.factory.onResume = { number in if number == index { resumed.fulfill() } }
        fixture.client.start(onTranscript: { _ in }, onError: { [weak fixture] error in fixture?.record(error) })
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertNotNil(fixture.factory.socket(index))
    }

    func installInitStub(hold: @escaping @Sendable () -> Void = {}) {
        StubURLProtocol.respond { request in
            hold()
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v2/live")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "synthetic")
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"synthetic","created_at":"synthetic","url":"wss://api.gladia.io/synthetic"}"#.utf8))
        }
    }

    static func transcript(_ text: String, final: Bool, confidence: Double) -> String {
        #"{"type":"transcript","data":{"is_final":"# + String(final)
            + #", "utterance":{"text":""# + text + #"", "confidence":"# + String(confidence) + "}}}"
    }
}
