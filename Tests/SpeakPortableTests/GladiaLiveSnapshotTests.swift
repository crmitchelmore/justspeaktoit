import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Real Gladia parser/run/callbacks through the existing held transports.
/// No provider, microphone, clock sleeps or platform capture is involved.
final class GladiaLiveSnapshotTests: XCTestCase {
    func testSnapshotKeepsFinalSegmentsLatestConfidenceAndOutstandingInterim() {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        defer { harness.client.cancel() }
        Self.emit(socket, "First.", id: "1", final: true, confidence: 0.8)
        Self.emit(socket, "Second.", id: "2", final: true)
        Self.emit(socket, "Third.", id: "3", final: true, confidence: 0.6)
        Self.emit(socket, "trailing draft", id: "4", final: false, confidence: 0.91)
        let snapshot = harness.client.transcriptSnapshot(captureDuration: 123)
        XCTAssertEqual(snapshot.confirmedText, "First. Second. Third.")
        XCTAssertEqual(snapshot.pendingInterim, "trailing draft")
        XCTAssertEqual(snapshot.resolvedDisplayText, "First. Second. Third. trailing draft")
        XCTAssertEqual(snapshot.latestUpdateConfidence, 0.91)
        XCTAssertEqual(snapshot.confidence, 0.7)
        XCTAssertEqual(snapshot.segments.map(\.text), ["First.", "Second.", "Third."])
        XCTAssertEqual(snapshot.segments.compactMap(\.confidence), [0.8, 0.6])
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.startTime == 0 && $0.endTime == 0 })
        XCTAssertNil(snapshot.duration, "Host duration is not provider metadata")
        XCTAssertNil(snapshot.cost)
        XCTAssertNil(snapshot.rawPayload)
        XCTAssertFalse(snapshot.isTerminal)
    }

    func testBlankRetryAndLatePartialDoNotChangeTheAcceptedProjection() {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        defer { harness.client.cancel() }
        Self.emit(socket, "Yes.", id: "1", final: true, confidence: 0.8)
        Self.emit(socket, "retried", id: "1", final: true, confidence: 0.1)
        Self.emit(socket, "stale draft", id: "1", final: false, confidence: 0.2)
        Self.emit(socket, "   ", id: "blank", final: true, confidence: 0.3)
        Self.emit(socket, "Yes.", id: "2", final: true)
        let snapshot = harness.client.transcriptSnapshot(captureDuration: 0)
        XCTAssertEqual(harness.log.finals, ["Yes.", "Yes."])
        XCTAssertEqual(snapshot.confirmedText, "Yes. Yes.")
        XCTAssertNil(snapshot.pendingInterim)
        XCTAssertNil(snapshot.latestUpdateConfidence)
        XCTAssertEqual(snapshot.confidence, 0.8)
        XCTAssertEqual(snapshot.segments.map(\.text), ["Yes.", "Yes."])
        XCTAssertNil(snapshot.segments.last?.confidence)
    }

    func testNilConfidenceAndTerminalFailureRetainDraftWithoutInventedFinal() async {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        defer { harness.client.cancel() }
        Self.emit(socket, "Kept.", id: "1", final: true)
        Self.emit(socket, "unconfirmed", id: "2", final: false)
        socket.failReceive()
        let whole = await harness.client.finishAndWait()
        XCTAssertEqual(whole, "Kept.", "The existing raw finish contract remains confirmed-only")
        let snapshot = harness.client.transcriptSnapshot(captureDuration: 0)
        XCTAssertEqual(snapshot.resolvedDisplayText, "Kept. unconfirmed")
        XCTAssertEqual(snapshot.segments.map(\.text), ["Kept."])
        XCTAssertNil(snapshot.latestUpdateConfidence)
        XCTAssertNil(snapshot.confidence)
        XCTAssertTrue(snapshot.isTerminal)
        XCTAssertEqual(harness.log.errors.first as? GladiaStreamingError, .connectionLost)
    }

    func testHealthyFinishReturnsConfirmedWholeWhileSnapshotKeepsLateFinalAndDraft() async throws {
        let harness = GladiaHarness()
        let client = harness.client
        let socket = harness.startOpen()
        client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        Self.emit(socket, "First.", id: "1", final: true, confidence: 0.8)
        let armed = expectation(description: "existing whole finish deadline armed")
        let done = expectation(description: "owned finish returned")
        let cleanedUp = XCTestExpectation(description: "owned finish task exited")
        harness.clock.whenScheduled(GladiaLive.finishBudget) { armed.fulfill() }
        let finishing = Task { () -> String? in
            defer { cleanedUp.fulfill() }
            let whole = await client.finishAndWait()
            done.fulfill()
            return whole
        }
        addTeardownBlock {
            finishing.cancel()
            client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [cleanedUp], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        defer { finishing.cancel(); client.cancel() }
        try await wait(armed)
        XCTAssertEqual(socket.sentTexts, [GladiaLiveProtocol.stopRecordingJSON])
        socket.completeSend()
        Self.emit(socket, "Tail.", id: "2", final: true, confidence: 0.6)
        Self.emit(socket, "still draft", id: "3", final: false, confidence: 0.4)
        socket.endSession()
        try await wait(done)
        let whole = await finishing.value
        XCTAssertEqual(whole, "First. Tail.")
        let snapshot = client.transcriptSnapshot(captureDuration: 0)
        XCTAssertEqual(snapshot.resolvedDisplayText, "First. Tail. still draft")
        XCTAssertEqual(snapshot.segments.map(\.text), ["First.", "Tail."])
        XCTAssertEqual(snapshot.confidence, 0.7)
        XCTAssertEqual(snapshot.latestUpdateConfidence, 0.4)
        XCTAssertTrue(snapshot.isTerminal)
        XCTAssertEqual(socket.sentAudio, [GladiaHarness.pcm(0)], "No framing or wire change in this checkpoint")
    }

}

extension GladiaLiveSnapshotTests {
    func testMalformedOptionalConfidenceDoesNotInventConfidenceOrDropText() {
        let harness = GladiaHarness()
        let socket = harness.startOpen()
        defer { harness.client.cancel() }
        let invalid = ["true", "false", "null", "\"0.9\"", "{}", "-0.1", "1.1", "1e308", "-1e308"]
        for (index, value) in invalid.enumerated() {
            let frame = #"{"type":"transcript","data":{"id":"\#(index)","is_final":true,"#
                + #""utterance":{"text":"Kept.","confidence":\#(value)}}}"#
            socket.emit(frame)
            XCTAssertNil(harness.client.transcriptSnapshot(captureDuration: 0).latestUpdateConfidence)
        }
        let snapshot = harness.client.transcriptSnapshot(captureDuration: 0)
        XCTAssertEqual(snapshot.segments.count, invalid.count)
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.confidence == nil })
        XCTAssertNil(snapshot.confidence)
        Self.emit(socket, "Zero.", id: "zero", final: true, confidence: 0)
        Self.emit(socket, "One.", id: "one", final: true, confidence: 1)
        let valid = harness.client.transcriptSnapshot(captureDuration: 0)
        XCTAssertEqual(valid.segments.compactMap(\.confidence), [0, 1])
        XCTAssertEqual(valid.latestUpdateConfidence, 1)
        XCTAssertEqual(valid.confidence, 0.5)
    }

    func testHeldCallbackDoesNotObserveQueuedEventConfidence() async throws {
        let harness = GladiaHarness()
        let client = harness.client
        let snapshots = SnapshotLog()
        let entered = expectation(description: "first transcript callback held")
        let returned = expectation(description: "owned receive thread returned")
        let release = DispatchSemaphore(value: 0)
        let cleanedUp = XCTestExpectation(description: "owned callback thread exited")
        addTeardownBlock {
            release.signal()
            client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [cleanedUp], timeout: 2)
            XCTAssertEqual(outcome, .completed, "Owned receive work must unwind on every test exit")
        }
        defer { release.signal(); client.cancel() }
        client.start(onTranscript: { text, _ in
            snapshots.append(client.transcriptSnapshot(captureDuration: 0))
            if text == "First." {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
                snapshots.append(client.transcriptSnapshot(captureDuration: 0))
            }
        }, onError: { XCTFail("Unexpected error: \($0)") })
        let socket = open(harness)
        DispatchQueue.global().async {
            Self.emit(socket, "First.", id: "1", final: true, confidence: 0.8)
            returned.fulfill()
            cleanedUp.fulfill()
        }
        try await wait(entered)
        Self.emit(socket, "Second.", id: "2", final: true, confidence: 0.6)
        XCTAssertEqual(snapshots.values.count, 1)
        client.sendAudio(GladiaHarness.pcm(0))
        XCTAssertEqual(socket.sentAudio.count, 1, "Capture admission never waits for the held callback")
        release.signal()
        try await wait(returned)
        XCTAssertEqual(snapshots.values.map(\.latestUpdateConfidence), [0.8, 0.8, 0.6])
        XCTAssertEqual(snapshots.values.map(\.confirmedText), ["First.", "First.", "First. Second."])
    }

    func testHeldCallbackKeepsItsProjectionWhileAnotherThreadReplacesTheRun() async throws {
        let harness = GladiaHarness()
        let client = harness.client
        let old = SnapshotLog()
        let entered = expectation(description: "old callback held")
        let returned = expectation(description: "old receive thread returned")
        let release = DispatchSemaphore(value: 0)
        let cleanedUp = XCTestExpectation(description: "owned callback thread exited")
        addTeardownBlock {
            release.signal()
            client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [cleanedUp], timeout: 2)
            XCTAssertEqual(outcome, .completed, "Owned receive work must unwind on every test exit")
        }
        defer { release.signal(); client.cancel() }
        client.start(onTranscript: { _, _ in
            old.append(client.transcriptSnapshot(captureDuration: 0))
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            old.append(client.transcriptSnapshot(captureDuration: 0))
        }, onError: { XCTFail("Unexpected old failure: \($0)") })
        let oldSocket = open(harness)
        DispatchQueue.global().async {
            Self.emit(oldSocket, "Old.", id: "old", final: true, confidence: 0.8)
            returned.fulfill()
            cleanedUp.fulfill()
        }
        try await wait(entered)
        let replacement = SnapshotLog()
        client.start(onTranscript: { _, _ in replacement.append(client.transcriptSnapshot(captureDuration: 0)) },
                     onError: { XCTFail("Unexpected replacement error: \($0)") })
        XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "")
        let socket = open(harness)
        Self.emit(socket, "New.", id: "new", final: true, confidence: 0.4)
        XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "New.")
        XCTAssertEqual(replacement.values.map(\.latestUpdateConfidence), [0.4])
        release.signal()
        try await wait(returned)
        XCTAssertEqual(old.values.map(\.confirmedText), ["Old.", "Old."])
        XCTAssertEqual(old.values.map(\.latestUpdateConfidence), [0.8, 0.8])
        XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "New.")
        XCTAssertEqual(socket.cancelCount, 0)
    }

}

extension GladiaLiveSnapshotTests {
    func testActiveCancellationReturnsWhileCallbackIsHeldWithoutPublishingFailure() async throws {
        let harness = GladiaHarness()
        let client = harness.client
        let snapshots = SnapshotLog()
        let entered = expectation(description: "active callback held")
        let returned = expectation(description: "owned receive thread returned after cancellation")
        let cleanedUp = XCTestExpectation(description: "cancelled callback thread exited")
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock {
            release.signal()
            client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [cleanedUp], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        defer { release.signal(); client.cancel() }
        client.start(onTranscript: { _, _ in
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            snapshots.append(client.transcriptSnapshot(captureDuration: 0))
        }, onError: { _ in XCTFail("Explicit cancellation must not publish a failure") })
        let socket = open(harness)
        DispatchQueue.global().async {
            Self.emit(socket, "Owned draft", id: "1", final: false, confidence: 0.9)
            returned.fulfill()
            cleanedUp.fulfill()
        }
        try await wait(entered)
        client.cancel()
        XCTAssertEqual(socket.cancelCount, 1, "Active cancellation returned while user callback remains held")
        XCTAssertTrue(client.transcriptSnapshot(captureDuration: 0).isTerminal)
        release.signal()
        try await wait(returned)
        XCTAssertEqual(snapshots.values.map(\.pendingInterim), ["Owned draft"])
        XCTAssertTrue(snapshots.values.allSatisfy { !$0.isTerminal })
        XCTAssertTrue(client.transcriptSnapshot(captureDuration: 0).isTerminal)
    }

    func testCancellationAndInputFailureDoNotWaitForCallbackOrChangeItsEvent() async throws {
        let harness = GladiaHarness()
        let client = harness.client
        let log = harness.log
        let snapshots = SnapshotLog()
        let entered = expectation(description: "transcript callback held")
        let returned = expectation(description: "owned receive callback returned")
        let reported = expectation(description: "deferred input failure reported")
        let release = DispatchSemaphore(value: 0)
        let cleanedUp = XCTestExpectation(description: "owned callback thread exited")
        addTeardownBlock {
            release.signal()
            client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [cleanedUp], timeout: 2)
            XCTAssertEqual(outcome, .completed, "Owned receive work must unwind on every test exit")
        }
        defer { release.signal(); client.cancel() }
        client.start(onTranscript: { _, _ in
            snapshots.append(client.transcriptSnapshot(captureDuration: 0))
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            snapshots.append(client.transcriptSnapshot(captureDuration: 0))
            log.note("callback-returned")
        }, onError: { error in log.fail(error); reported.fulfill() })
        let socket = open(harness)
        DispatchQueue.global().async {
            Self.emit(socket, "Kept.", id: "1", final: true, confidence: 0.9)
            returned.fulfill()
            cleanedUp.fulfill()
        }
        try await wait(entered)
        client.sendAudio(Data([1, 2, 3]))
        client.cancel()
        XCTAssertTrue(client.transcriptSnapshot(captureDuration: 0).isTerminal)
        XCTAssertTrue(log.errors.isEmpty, "Failure cannot overtake its admitted callback")
        release.signal()
        try await wait(returned)
        try await wait(reported)
        XCTAssertEqual(log.timeline, ["callback-returned", "error"])
        XCTAssertEqual(snapshots.values.map(\.latestUpdateConfidence), [0.9, 0.9])
        XCTAssertTrue(snapshots.values.allSatisfy { !$0.isTerminal }, "Callback projection is its original event")
        XCTAssertTrue(client.transcriptSnapshot(captureDuration: 0).isTerminal)
    }

    func testSameThreadNestedReplacementRestoresOnlyTheOuterCallbackProjection() {
        let harness = GladiaHarness()
        let client = harness.client
        let snapshots = SnapshotLog()
        defer { client.cancel() }
        client.start(onTranscript: { _, _ in
            snapshots.append(client.transcriptSnapshot(captureDuration: 0))
            client.start(onTranscript: { _, _ in
                snapshots.append(client.transcriptSnapshot(captureDuration: 0))
            }, onError: { XCTFail("Unexpected nested failure: \($0)") })
            let replacement = self.open(harness)
            Self.emit(replacement, "Replacement.", id: "new", final: true, confidence: 0.4)
            snapshots.append(client.transcriptSnapshot(captureDuration: 0))
        }, onError: { XCTFail("Unexpected outer failure: \($0)") })
        let old = open(harness)
        Self.emit(old, "Outer.", id: "old", final: true, confidence: 0.8)
        XCTAssertEqual(snapshots.values.map(\.confirmedText), ["Outer.", "Replacement.", "Outer."])
        XCTAssertEqual(snapshots.values.map(\.latestUpdateConfidence), [0.8, 0.4, 0.8])
        XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "Replacement.")
        XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).latestUpdateConfidence, 0.4)
    }

}

private extension GladiaLiveSnapshotTests {
    func open(_ harness: GladiaHarness) -> GladiaFakeSocket {
        harness.sessions.grant()
        let socket = harness.socket
        socket.open()
        return socket
    }

    static func emit(
        _ socket: GladiaFakeSocket, _ text: String, id: String, final: Bool, confidence: Double? = nil
    ) {
        var utterance: [String: Any] = ["text": text]
        if let confidence { utterance["confidence"] = confidence }
        let frame: [String: Any] = [
            "type": "transcript", "data": ["id": id, "is_final": final, "utterance": utterance]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: frame)
            socket.emitBinary(data)
        } catch {
            XCTFail("Synthetic transcript could not encode: \(error)")
        }
    }

    func wait(_ signal: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [signal], timeout: 2) == .completed else {
            XCTFail("Owned fixture stage did not complete: \(signal.expectationDescription)")
            throw FixtureTimeout()
        }
    }

    struct FixtureTimeout: Error {}
}

private final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StreamingTranscriptSnapshot] = []
    var values: [StreamingTranscriptSnapshot] { lock.withLock { stored } }
    func append(_ snapshot: StreamingTranscriptSnapshot) { lock.withLock { stored.append(snapshot) } }
}
