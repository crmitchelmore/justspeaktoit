import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Actual Core Gladia client → shared Mac controller, with held transports
/// and capture bypassed at its existing test seam. No route is changed.
@MainActor
final class SharedClientGladiaBoundaryTests: XCTestCase {
    func testReorderedJobsDeliverEachOriginalBoundaryAfterItsCumulativeDisplay() async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        socket.emit(try GladiaControllerBoundaryFixture.frame("First.", id: "1"))
        socket.emit(try GladiaControllerBoundaryFixture.frame("Second.", id: "2", confidence: 0.6))
        fixture.updates.deliverAll(reversed: true)
        XCTAssertEqual(fixture.delegate.events, [
            .partial("First."), .boundary("First."), .partial("First. Second."), .boundary("Second.")
        ])
        XCTAssertEqual(fixture.delegate.updates.map(\.confidence), [0.8, 0.6])
        let stopping = try await beginStop(fixture)
        try await completeStop(fixture, stopping)
        XCTAssertEqual(fixture.delegate.results.map(\.text), ["First. Second."])
        XCTAssertEqual(fixture.delegate.events.count, 4, "No duplicate display or whole-history finish boundary")
    }

    func testNormalStopRetainsQueuedPairsUntilTerminalDrainAndKeepsDraft() async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        socket.emit(try GladiaControllerBoundaryFixture.frame("First.", id: "1"))
        let stopping = try await beginStop(fixture)
        socket.emit(try GladiaControllerBoundaryFixture.frame("Tail.", id: "2", confidence: 0.6))
        socket.emit(try GladiaControllerBoundaryFixture.frame("draft", id: "3", final: false, confidence: 0.4))
        fixture.updates.deliverAll(reversed: true)
        XCTAssertTrue(fixture.delegate.events.isEmpty, "Normal stopping retains rather than consumes the pairs")
        try await completeStop(fixture, stopping)
        XCTAssertEqual(fixture.delegate.events, [
            .partial("First."), .boundary("First."), .partial("First. Tail."), .boundary("Tail."),
            .partial("First. Tail. draft")
        ])
        let result = try XCTUnwrap(fixture.delegate.results.first)
        XCTAssertEqual(result.text, "First. Tail. draft")
        XCTAssertEqual(result.segments.map(\.text), ["First.", "Tail."])
        XCTAssertEqual(result.confidence, 0.7)
        XCTAssertEqual(fixture.delegate.updates.last?.confidence, 0.4)
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testAllAdmittedPairsPrecedeFailureAndNeverProduceTerminalSuccess() async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        socket.emit(try GladiaControllerBoundaryFixture.frame("First.", id: "1"))
        socket.emit(try GladiaControllerBoundaryFixture.frame("Tail.", id: "2"))
        socket.emit(try GladiaControllerBoundaryFixture.frame("draft", id: "3", final: false))
        socket.fail()
        await fixture.controller.stop()
        fixture.updates.deliverAll(reversed: true)
        XCTAssertEqual(fixture.delegate.events, [
            .partial("First."), .boundary("First."), .partial("First. Tail."), .boundary("Tail."),
            .partial("First. Tail. draft"), .error
        ])
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
    }

    func testCancelledStopAndReplacementDiscardOldQueuedPairs() async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let old = try XCTUnwrap(fixture.socket)
        old.emit(try GladiaControllerBoundaryFixture.frame("Old.", id: "old"))
        let stopping = try await beginStop(fixture)
        stopping.task.cancel()
        try await wait(stopping.done)
        fixture.updates.deliverAll(reversed: true)
        XCTAssertFalse(fixture.delegate.events.contains(.boundary("Old.")))
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        XCTAssertTrue(fixture.delegate.errors.last is CancellationError)
        fixture.delegate.events.removeAll()
        try await fixture.start()
        let replacement = try XCTUnwrap(fixture.socket)
        replacement.emit(try GladiaControllerBoundaryFixture.frame("New.", id: "new"))
        fixture.updates.deliverAll(reversed: true)
        XCTAssertEqual(fixture.delegate.events, [.partial("New."), .boundary("New.")])
        XCTAssertEqual(replacement.cancels, 0)
        let nextStop = try await beginStop(fixture)
        try await completeStop(fixture, nextStop)
        XCTAssertEqual(fixture.delegate.results.map(\.text), ["New."])
    }

    func testDelegateCancellationDuringPairedUpdateCannotEmitOldBoundaryOrSuccess() async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        socket.emit(try GladiaControllerBoundaryFixture.frame("Owned.", id: "1"))
        let stopping = try await beginStop(fixture)
        fixture.delegate.onUpdate = { stopping.task.cancel() }
        try await completeStop(fixture, stopping)
        XCTAssertFalse(fixture.delegate.events.contains(.boundary("Owned.")))
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        XCTAssertTrue(fixture.delegate.errors.last is CancellationError)
    }

    func testLatestDraftUpdateCancellationCannotSendOldPartialOrFailureToReplacement() async throws {
        try await latestDraftCancellation(afterPartial: false)
    }

    func testLatestDraftPartialCancellationCannotSendOldFailureToReplacement() async throws {
        try await latestDraftCancellation(afterPartial: true)
    }

    func testHealthyDraftCancellationAndDelegateSwapCannotReplayOldCancellationOrSuccess() async throws {
        try await latestDraftCancellation(afterPartial: false, failureBeforeStop: false)
    }

    func testHealthyDraftDelegateSwapAloneCannotReceiveOldPartialOrSuccess() async throws {
        try await latestDraftCancellation(afterPartial: false, failureBeforeStop: false, cancelTask: false)
    }

    func testFailedDraftDelegateSwapAloneCannotReceiveOldPartialOrFailure() async throws {
        try await latestDraftCancellation(afterPartial: false, cancelTask: false)
    }

    func testReleasedDelegateIsNotRetainedAndReplacementCannotReceiveItsRun() async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        var original: GladiaControllerBoundaryDelegate? = GladiaControllerBoundaryDelegate()
        weak var released = original
        fixture.controller.delegate = original
        try await fixture.start()
        original = nil
        XCTAssertNil(released, "The delivery receipt must not retain the original delegate")
        let replacement = GladiaControllerBoundaryDelegate()
        fixture.controller.delegate = replacement
        let socket = try XCTUnwrap(fixture.socket)
        socket.emit(try GladiaControllerBoundaryFixture.frame("Old.", id: "old"))
        socket.emit(try GladiaControllerBoundaryFixture.frame("draft", id: "draft", final: false))
        fixture.updates.deliverAll(reversed: true)
        let stopping = try await beginStop(fixture)
        try await completeStop(fixture, stopping)
        XCTAssertTrue(replacement.updates.isEmpty)
        XCTAssertTrue(replacement.events.isEmpty)
        XCTAssertTrue(replacement.results.isEmpty)
        try await fixture.start()
        let next = try XCTUnwrap(fixture.socket)
        next.emit(try GladiaControllerBoundaryFixture.frame("New.", id: "new"))
        fixture.updates.deliverAll(reversed: true)
        XCTAssertEqual(replacement.events, [.partial("New."), .boundary("New.")])
        let nextStop = try await beginStop(fixture)
        try await completeStop(fixture, nextStop)
        XCTAssertEqual(replacement.results.map(\.text), ["New."])
    }

    func testAlreadyDisplayedFinalIsNotReplayedWhenItsBoundaryArrivesLater() async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        let entered = expectation(description: "ordinary update queued before boundary")
        let returned = expectation(description: "owned receive returned")
        let cleanedUp = XCTestExpectation(description: "owned receive exited")
        let release = DispatchSemaphore(value: 0)
        fixture.updates.holdNextEnqueue(entered: entered, release: release)
        addTeardownBlock { @MainActor in
            release.signal(); fixture.client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [cleanedUp], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        defer { release.signal() }
        let frame = try GladiaControllerBoundaryFixture.frame("First.", id: "1")
        DispatchQueue.global().async {
            socket.emit(frame)
            returned.fulfill(); cleanedUp.fulfill()
        }
        try await wait(entered)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.events, [.partial("First.")])
        release.signal()
        try await wait(returned)
        socket.emit(try GladiaControllerBoundaryFixture.frame("Second.", id: "2"))
        fixture.updates.deliverAll(reversed: true)
        XCTAssertEqual(fixture.delegate.events, [
            .partial("First."), .boundary("First."), .partial("First. Second."), .boundary("Second.")
        ])
        let stopping = try await beginStop(fixture)
        try await completeStop(fixture, stopping)
    }
}

private extension SharedClientGladiaBoundaryTests {
    func latestDraftCancellation(
        afterPartial: Bool, failureBeforeStop: Bool = true, cancelTask: Bool = true
    ) async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        socket.emit(try GladiaControllerBoundaryFixture.frame("First.", id: "1"))
        socket.emit(try GladiaControllerBoundaryFixture.frame("Tail.", id: "2"))
        socket.emit(try GladiaControllerBoundaryFixture.frame("draft", id: "3", final: false))
        let replacement = GladiaControllerBoundaryDelegate()
        let stopping: GladiaControllerBoundaryFixture.Stopping
        if failureBeforeStop {
            socket.fail()
            stopping = ownStop(fixture)
        } else {
            stopping = try await beginStop(fixture)
        }
        let cancelAndReplace = {
            if cancelTask { stopping.task.cancel() }
            fixture.controller.delegate = replacement
        }
        if afterPartial {
            fixture.delegate.onPartial = {
                if fixture.delegate.events.last == .partial("First. Tail. draft") { cancelAndReplace() }
            }
        } else {
            fixture.delegate.onUpdate = {
                if fixture.delegate.updates.last?.text == "First. Tail. draft" { cancelAndReplace() }
            }
        }
        if !failureBeforeStop {
            try socket.completeSend()
            socket.emit(#"{"type":"end_session"}"#)
        }
        try await wait(stopping.done)
        var expected: [GladiaControllerBoundaryDelegate.Event] = [
            .partial("First."), .boundary("First."), .partial("First. Tail."), .boundary("Tail.")
        ]
        if afterPartial { expected.append(.partial("First. Tail. draft")) }
        XCTAssertEqual(fixture.delegate.events, expected)
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
        XCTAssertTrue(replacement.events.isEmpty, "No remaining old partial or failure may reach a new delegate")
        XCTAssertTrue(replacement.results.isEmpty)
        fixture.delegate.onUpdate = nil; fixture.delegate.onPartial = nil
        try await fixture.start()
        let next = try XCTUnwrap(fixture.socket)
        next.emit(try GladiaControllerBoundaryFixture.frame("New.", id: "new"))
        fixture.updates.deliverAll(reversed: true)
        XCTAssertEqual(replacement.events, [.partial("New."), .boundary("New.")])
        let nextStop = try await beginStop(fixture)
        try await completeStop(fixture, nextStop)
        XCTAssertEqual(replacement.results.map(\.text), ["New."])
    }

    func beginStop(
        _ fixture: GladiaControllerBoundaryFixture
    ) async throws -> GladiaControllerBoundaryFixture.Stopping {
        let socket = try XCTUnwrap(fixture.socket)
        let sent = expectation(description: "existing Gladia stop_recording handed off")
        socket.observeSends { message in
            if case .text(let text) = message, text == #"{"type":"stop_recording"}"# { sent.fulfill() }
        }
        let stopping = ownStop(fixture)
        try await wait(sent)
        return stopping
    }

    func ownStop(_ fixture: GladiaControllerBoundaryFixture) -> GladiaControllerBoundaryFixture.Stopping {
        let stopping = fixture.stop()
        addTeardownBlock { @MainActor in
            stopping.task.cancel(); fixture.client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [stopping.cleanedUp], timeout: 2)
            XCTAssertEqual(outcome, .completed, "Every owned stop task must unwind")
        }
        return stopping
    }

    func completeStop(
        _ fixture: GladiaControllerBoundaryFixture, _ stopping: GladiaControllerBoundaryFixture.Stopping
    ) async throws {
        let socket = try XCTUnwrap(fixture.socket)
        try socket.completeSend()
        socket.emit(#"{"type":"end_session"}"#)
        try await wait(stopping.done)
        fixture.updates.deliverAll(reversed: true)
    }

    func wait(_ signal: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [signal], timeout: 2) == .completed else {
            XCTFail("Owned Gladia stage did not finish: \(signal.expectationDescription)")
            throw Timeout()
        }
    }
    struct Timeout: Error {}
}
