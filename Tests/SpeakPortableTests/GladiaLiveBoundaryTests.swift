import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class GladiaLiveBoundaryTests: XCTestCase {
    func testOriginalFinalUtterancesFollowTheirDisplayWithTheSameEventSnapshot() {
        let harness = GladiaHarness()
        let client = harness.client, log = harness.log
        defer { client.cancel(); client.onUtteranceBoundary = nil }
        client.onUtteranceBoundary = { text in
            XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).latestUpdateConfidence, 0.8)
            log.note("boundary:\(text)")
        }
        client.start(onTranscript: { text, final in
            XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).latestUpdateConfidence, 0.8)
            log.transcript(text, isFinal: final)
        }, onError: { log.fail($0) })
        let socket = open(harness)
        socket.emit(Self.frame("Yes.", id: "1"))
        socket.emit(Self.frame("retry", id: "1"))
        socket.emit(Self.frame("stale draft", id: "1", final: false))
        socket.emit(Self.frame("  ", id: "blank"))
        socket.emit(Self.frame("draft", id: "2", final: false))
        socket.emit(Self.frame("Yes.", id: "2"))
        XCTAssertEqual(log.timeline, [
            "final:Yes.", "boundary:Yes.", "partial:draft", "final:Yes.", "boundary:Yes."
        ])
        XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "Yes. Yes.")
        XCTAssertTrue(log.errors.isEmpty)
    }

    func testFailureAfterAdmittedFinalPreservesBoundary() async throws {
        try await heldTranscript(.failure)
    }

    func testActiveCancelDiscardsAnAdmittedButUndeliveredBoundary() async throws {
        try await heldTranscript(.cancel)
    }

    func testCancelAfterFailureStillDiscardsItsUndeliveredBoundary() async throws {
        try await heldTranscript(.failureThenCancel)
    }

    func testReplacementDiscardsOldBoundaryAndKeepsReplacementOwner() async throws {
        try await heldTranscript(.replacement)
    }

    func testBoundaryCallbackIsCountedBeforeFailureAndGracefulFinishCanReturn() async throws {
        let harness = GladiaHarness()
        let client = harness.client, log = harness.log
        let entered = expectation(description: "boundary callback held")
        let returned = expectation(description: "owned receive returned")
        let callbackExited = XCTestExpectation(description: "owned boundary thread exited")
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock {
            release.signal(); client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [callbackExited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        defer { release.signal(); client.cancel(); client.onUtteranceBoundary = nil }
        client.onUtteranceBoundary = { text in
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            log.note("boundary:\(text)")
        }
        client.start(onTranscript: { log.transcript($0, isFinal: $1) }, onError: { log.fail($0) })
        let socket = open(harness)
        DispatchQueue.global().async {
            socket.emit(Self.frame("Tail.", id: "1"))
            returned.fulfill(); callbackExited.fulfill()
        }
        try await wait(entered)
        let done = expectation(description: "finish returned after admitted callback and report")
        let taskExited = XCTestExpectation(description: "owned finish exited")
        let sent = observeStop(socket)
        let finishing = Task {
            defer { taskExited.fulfill() }
            let whole = await client.finishAndWait()
            log.note("finish:\(whole ?? "nil")")
            done.fulfill()
        }
        addTeardownBlock {
            finishing.cancel(); client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [taskExited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        defer { finishing.cancel(); client.cancel() }
        try await wait(sent)
        socket.completeSend(URLError(.networkConnectionLost))
        XCTAssertEqual(client.currentStage, .closed)
        XCTAssertEqual(log.timeline, ["final:Tail."], "Neither error nor finish may overtake the boundary")
        release.signal()
        try await wait(returned)
        try await wait(done)
        XCTAssertEqual(log.timeline, ["final:Tail.", "boundary:Tail.", "error", "finish:Tail."])
        XCTAssertEqual(log.errors.first as? GladiaStreamingError, .connectionLost)
    }

    func testNestedReplacementCannotDispatchOldBoundaryToNewCallback() {
        let harness = GladiaHarness()
        let client = harness.client, log = harness.log
        defer { client.cancel(); client.onUtteranceBoundary = nil }
        client.onUtteranceBoundary = { log.note("old-boundary:\($0)") }
        client.start(onTranscript: { text, final in
            log.transcript(text, isFinal: final)
            client.onUtteranceBoundary = { text in
                XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "New.")
                log.note("new-boundary:\(text)")
            }
            client.start(onTranscript: { log.transcript($0, isFinal: $1) }, onError: { log.fail($0) })
            let socket = self.open(harness)
            socket.emit(Self.frame("New.", id: "new"))
            XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "Old.")
        }, onError: { log.fail($0) })
        open(harness).emit(Self.frame("Old.", id: "old"))
        XCTAssertEqual(log.timeline, ["final:Old.", "final:New.", "new-boundary:New."])
        XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "New.")
    }
}

private extension GladiaLiveBoundaryTests {
    enum Disposition {
        case failure, cancel, failureThenCancel, replacement

        var expectedTimeline: [String] {
            switch self {
            case .failure: ["final:Old.", "display-returned", "boundary:Old.", "error"]
            case .cancel: ["final:Old.", "display-returned"]
            case .failureThenCancel: ["final:Old.", "display-returned", "error"]
            case .replacement: ["final:Old.", "final:New.", "new-boundary:New.", "display-returned"]
            }
        }
    }

    func heldTranscript(_ disposition: Disposition) async throws {
        let harness = GladiaHarness()
        let client = harness.client, log = harness.log
        let entered = expectation(description: "ordinary transcript callback held")
        let returned = expectation(description: "owned receive returned")
        let cleanedUp = XCTestExpectation(description: "owned receive thread exited")
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock {
            release.signal(); client.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [cleanedUp], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        defer { release.signal(); client.cancel(); client.onUtteranceBoundary = nil }
        client.onUtteranceBoundary = { text in
            XCTAssertEqual(client.transcriptSnapshot(captureDuration: 0).confirmedText, "Old.")
            log.note("boundary:\(text)")
        }
        client.start(onTranscript: { text, final in
            log.transcript(text, isFinal: final)
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            log.note("display-returned")
        }, onError: { log.fail($0) })
        let old = open(harness)
        DispatchQueue.global().async {
            old.emit(Self.frame("Old.", id: "old"))
            returned.fulfill(); cleanedUp.fulfill()
        }
        try await wait(entered)
        switch disposition {
        case .failure:
            client.sendAudio(Data([1, 2, 3]))
        case .cancel:
            client.cancel()
        case .failureThenCancel:
            client.sendAudio(Data([1, 2, 3])); client.cancel()
        case .replacement:
            client.onUtteranceBoundary = { log.note("new-boundary:\($0)") }
            client.start(onTranscript: { log.transcript($0, isFinal: $1) }, onError: { log.fail($0) })
            open(harness).emit(Self.frame("New.", id: "new"))
        }
        XCTAssertFalse(log.timeline.contains("display-returned"), "The operation returned before callback release")
        release.signal()
        try await wait(returned)
        XCTAssertEqual(log.timeline, disposition.expectedTimeline)
    }

    func observeStop(_ socket: GladiaFakeSocket) -> XCTestExpectation {
        let sent = expectation(description: "owned stop send is in flight")
        socket.onSend = { message in
            if case .text(let text) = message, text == GladiaLiveProtocol.stopRecordingJSON { sent.fulfill() }
        }
        return sent
    }

    func open(_ harness: GladiaHarness) -> GladiaFakeSocket {
        harness.sessions.grant()
        let socket = harness.socket
        socket.open()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        return socket
    }

    static func frame(_ text: String, id: String, final: Bool = true) -> String {
        let payload: [String: Any] = [
            "type": "transcript",
            "data": ["id": id, "is_final": final, "utterance": ["text": text, "confidence": 0.8]]
        ]
        let bytes = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    func wait(_ signal: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [signal], timeout: 2) == .completed else {
            XCTFail("Owned stage did not finish: \(signal.expectationDescription)")
            throw Timeout()
        }
    }

    struct Timeout: Error {}
}
