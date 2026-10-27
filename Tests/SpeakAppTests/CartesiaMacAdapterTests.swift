import Foundation
import XCTest
@testable import SpeakApp
@testable import SpeakCore

final class CartesiaMacAdapterTests: XCTestCase {
    func testOriginalSessionInitializerAndCaptureFramingRemainAvailable() {
        let constructor: (String, String, Int, URLSession) -> CartesiaLiveTranscriber =
            CartesiaLiveTranscriber.init(apiKey:model:sampleRate:session:)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        constructor("synthetic", "ink-2", 16_000, session).stop()
        XCTAssertEqual(CartesiaLiveTranscriber.preferredChunkBytes, 3_200)
        XCTAssertEqual(CartesiaLiveTranscriber.minimumChunkBytes, 1_600)
    }

    func testStoppedAdapterCannotRestartOrAdmitAudio() {
        let fixture = CartesiaMacFixture()
        fixture.adapter.stop()
        fixture.adapter.start(onTranscript: { _, _ in XCTFail("Retired callback") }, onError: { _ in
            XCTFail("Retired adapter must not start a new Core run")
        })
        fixture.adapter.sendAudio(Data(repeating: 1, count: 3_200))
        XCTAssertEqual(fixture.socket.resumes, 0)
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        XCTAssertTrue(fixture.adapter.snapshot.error is CancellationError)
    }

    func testPCMAndResidualDrainBeforeCloseThenLateTurnsAndDraftReplaceWholeOnce() async throws {
        let fixture = CartesiaMacFixture()
        fixture.start()
        fixture.socket.emit(Self.turn("First.", final: true))
        fixture.adapter.sendAudio(Data(repeating: 1, count: 4_200))
        let closeSent = expectation(description: "Close follows completed audio")
        let residualSent = expectation(description: "Padded residual actually enqueued")
        fixture.socket.onAudio = { audio in if audio.count == 1_600 { residualSent.fulfill() } }
        fixture.socket.onClose = { closeSent.fulfill() }
        let outcome = CartesiaMacOutcome()
        let settled = expectation(description: "Whole finish settled")
        let pending = Task { outcome.store(await fixture.adapter.finishAndWait()); settled.fulfill() }
        defer { pending.cancel(); fixture.adapter.stop() }
        fixture.socket.completeSend()
        await fulfillment(of: [residualSent], timeout: 2)
        XCTAssertEqual(fixture.socket.binary.map(\.count), [3_200, 1_600])
        XCTAssertEqual(fixture.socket.binary.last?.prefix(1_000), Data(repeating: 1, count: 1_000))
        XCTAssertTrue(fixture.socket.text.isEmpty)
        fixture.socket.completeSend()
        await fulfillment(of: [closeSent], timeout: 2)
        XCTAssertEqual(fixture.socket.text, [#"{"type":"close"}"#])
        fixture.socket.completeSend()
        fixture.socket.emit(Self.turn("Late.", final: true))
        fixture.socket.emit(Self.turn("open draft", final: false))
        XCTAssertNil(outcome.value)
        fixture.socket.closeNormally()
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.transcript.displayText, "First. Late. open draft")
        XCTAssertEqual(result.transcript.confirmedText, "First. Late.")
        XCTAssertEqual(result.transcript.pendingInterim, "open draft")
        XCTAssertEqual(result.transcript.segments.map(\.text), ["First.", "Late."])
        XCTAssertEqual(fixture.delivered, ["First."], "Healthy trailing turns are consumed by the whole result")
        XCTAssertNil(result.error)
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.adapter.finalisationBudget, 3.3, accuracy: 0.001)
        XCTAssertTrue(fixture.clock.delays.contains { abs($0 - 1.8) < 0.001 }, "One grace after close")
    }

    func testHealthyCloseWithoutNewFinalKeepsTheOpenDraft() async throws {
        let fixture = CartesiaMacFixture()
        fixture.start()
        fixture.socket.emit(Self.turn("Confirmed.", final: true))
        fixture.socket.emit(Self.turn("unconfirmed draft", final: false))
        let result = try await finishNormally(fixture)
        XCTAssertEqual(result.transcript.displayText, "Confirmed. unconfirmed draft")
        XCTAssertEqual(result.transcript.confirmedText, "Confirmed.")
        XCTAssertEqual(result.transcript.pendingInterim, "unconfirmed draft")
        XCTAssertNil(result.error)
    }

    func testSilentFinishKeepsAnEmptySnapshot() async throws {
        let fixture = CartesiaMacFixture()
        fixture.start()
        let result = try await finishNormally(fixture)
        XCTAssertTrue(result.transcript.displayText?.isEmpty ?? true)
        XCTAssertTrue(result.transcript.segments.isEmpty)
        XCTAssertNil(result.error)
    }

    func testFailureKeepsNewTrailingFinalAndDraftAndPublishesErrorBeforeFinish() async throws {
        let fixture = CartesiaMacFixture()
        fixture.start()
        fixture.socket.emit(Self.turn("Confirmed.", final: true))
        let closeSent = expectation(description: "Close send held")
        fixture.socket.onClose = { closeSent.fulfill() }
        let outcome = CartesiaMacOutcome()
        let failed = expectation(description: "Failure actually published")
        fixture.onError = { _ in
            XCTAssertNotNil(fixture.adapter.snapshot.error)
            XCTAssertNil(outcome.value)
            failed.fulfill()
        }
        let settled = expectation(description: "Failed finish settled")
        let pending = Task { outcome.store(await fixture.adapter.finishAndWait()); settled.fulfill() }
        defer { pending.cancel(); fixture.adapter.stop() }
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.emit(Self.turn("New tail.", final: true))
        fixture.socket.emit(Self.turn("retained draft", final: false))
        fixture.socket.completeSend(error: URLError(.networkConnectionLost))
        await fulfillment(of: [failed, settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.transcript.displayText, "Confirmed. New tail. retained draft")
        XCTAssertEqual(result.transcript.segments.map(\.text), ["Confirmed.", "New tail."])
        XCTAssertEqual(result.transcript.pendingInterim, "retained draft")
        XCTAssertNotNil(result.error)
        XCTAssertNotNil(fixture.adapter.takeFailureForReporting())
        XCTAssertNil(fixture.adapter.takeFailureForReporting())
    }

    func testCancelledFinishAndLateCallbacksCannotTouchUnrelatedRecording() async throws {
        let old = CartesiaMacFixture(), current = CartesiaMacFixture()
        old.start()
        current.start()
        defer { old.adapter.stop(); current.adapter.stop() }
        old.socket.emit(Self.turn("Old draft", final: false))
        current.socket.emit(Self.turn("Current.", final: true))
        let closeSent = expectation(description: "Old close admitted")
        old.socket.onClose = { closeSent.fulfill() }
        let outcome = CartesiaMacOutcome()
        let settled = expectation(description: "Cancelled old finish settled")
        let pending = Task { outcome.store(await old.adapter.finishAndWait()); settled.fulfill() }
        defer { pending.cancel() }
        await fulfillment(of: [closeSent], timeout: 2)
        pending.cancel()
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.transcript.displayText, "Old draft")
        XCTAssertTrue(result.error is CancellationError)
        old.socket.emit(Self.turn("Stale.", final: true))
        old.socket.completeSend(error: URLError(.networkConnectionLost))
        XCTAssertEqual(current.adapter.snapshot.transcript.displayText, "Current.")
        XCTAssertNil(current.adapter.snapshot.error)
        XCTAssertEqual(current.socket.cancels, 0)
        XCTAssertEqual(old.socket.cancels, 1)
    }

    func testHealthyTerminalOutcomeSurvivesALateAlreadyCancelledFinishCaller() async throws {
        let fixture = CartesiaMacFixture()
        fixture.start()
        fixture.socket.emit(Self.turn("Complete.", final: true))
        let original = try await finishNormally(fixture)
        let closes = fixture.socket.text
        let cancellations = fixture.socket.cancels
        let outcome = CartesiaMacOutcome()
        let settled = expectation(description: "Late cancelled caller returned cached terminal")
        let late = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            outcome.store(await fixture.adapter.finishAndWait())
            settled.fulfill()
        }
        defer { late.cancel(); fixture.adapter.stop() }
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertNil(original.error)
        XCTAssertNil(result.error)
        XCTAssertNil(fixture.adapter.snapshot.error)
        XCTAssertEqual(result.transcript.displayText, original.transcript.displayText)
        XCTAssertEqual(result.transcript.segments.map(\.text), ["Complete."])
        XCTAssertEqual(fixture.socket.text, closes)
        XCTAssertEqual(fixture.socket.cancels, cancellations)
    }

    func testOneCancelledFinishPublishesTheSameCancellationToItsJoiner() async throws {
        let fixture = CartesiaMacFixture()
        fixture.start()
        fixture.socket.emit(Self.turn("Saved draft", final: false))
        let closeSent = expectation(description: "Owned close held")
        fixture.socket.onClose = { closeSent.fulfill() }
        let first = CartesiaMacOutcome(), second = CartesiaMacOutcome()
        let settled = expectation(description: "Both cancelled finish outcomes settled")
        settled.expectedFulfillmentCount = 2
        let taskOne = Task { first.store(await fixture.adapter.finishAndWait()); settled.fulfill() }
        defer { taskOne.cancel(); fixture.adapter.stop() }
        await fulfillment(of: [closeSent], timeout: 2)
        let taskTwo = Task { second.store(await fixture.adapter.finishAndWait()); settled.fulfill() }
        defer { taskTwo.cancel() }
        let joined = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.adapter.pendingFinishes == 2
        }, object: nil)
        await fulfillment(of: [joined], timeout: 2)
        taskOne.cancel()
        await fulfillment(of: [settled], timeout: 2)
        let resultOne = try XCTUnwrap(first.value), resultTwo = try XCTUnwrap(second.value)
        XCTAssertTrue(resultOne.error is CancellationError)
        XCTAssertTrue(resultTwo.error is CancellationError)
        XCTAssertEqual(resultOne.transcript.displayText, "Saved draft")
        XCTAssertEqual(resultTwo.transcript.displayText, resultOne.transcript.displayText)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testLateFinishJoinerWaitsForTheOwnedErrorCallbackToReturn() async throws {
        let fixture = CartesiaMacFixture()
        fixture.start()
        let reportGate = CartesiaMacHold()
        let entered = expectation(description: "Error callback entered")
        let returned = expectation(description: "Error callback returned")
        fixture.onError = { _ in
            entered.fulfill()
            XCTAssertTrue(reportGate.wait())
            returned.fulfill()
        }
        let closeSent = expectation(description: "Close held")
        fixture.socket.onClose = { closeSent.fulfill() }
        let first = CartesiaMacOutcome(), second = CartesiaMacOutcome()
        let settled = expectation(description: "Both callers settled")
        settled.expectedFulfillmentCount = 2
        let taskOne = Task { first.store(await fixture.adapter.finishAndWait()); settled.fulfill() }
        defer { taskOne.cancel(); reportGate.release(); fixture.adapter.stop() }
        await fulfillment(of: [closeSent], timeout: 2)
        DispatchQueue.global().async { fixture.socket.completeSend(error: URLError(.networkConnectionLost)) }
        await fulfillment(of: [entered], timeout: 2)
        let taskTwo = Task { second.store(await fixture.adapter.finishAndWait()); settled.fulfill() }
        defer { taskTwo.cancel() }
        let joined = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.adapter.pendingFinishes == 2
        }, object: nil)
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertNil(first.value)
        XCTAssertNil(second.value)
        reportGate.release()
        await fulfillment(of: [returned, settled], timeout: 2)
        XCTAssertNotNil(try XCTUnwrap(first.value).error)
        XCTAssertNotNil(try XCTUnwrap(second.value).error)
    }
}

private extension CartesiaMacAdapterTests {
    static func turn(_ text: String, final: Bool) -> String {
        #"{"type":"turn."# + (final ? "end" : "update") + #"","transcript":""# + text + #""}"#
    }

    func finishNormally(_ fixture: CartesiaMacFixture) async throws -> CartesiaLiveTranscriber.Snapshot {
        let closeSent = expectation(description: "Close handed to the owned socket")
        fixture.socket.onClose = { closeSent.fulfill() }
        let outcome = CartesiaMacOutcome()
        let settled = expectation(description: "Normal closure settled")
        let pending = Task { outcome.store(await fixture.adapter.finishAndWait()); settled.fulfill() }
        defer { pending.cancel(); fixture.adapter.stop() }
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.closeNormally()
        await fulfillment(of: [settled], timeout: 2)
        return try XCTUnwrap(outcome.value)
    }
}
