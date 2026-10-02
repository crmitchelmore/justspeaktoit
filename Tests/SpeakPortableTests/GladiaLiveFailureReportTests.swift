import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// A failure retires its run at once, but its report, `onError`, is delivered
/// after the lock is released, possibly on a transport's background thread.
/// Every finish, whether registered before the failure or joining while the
/// report is still pending, returns only once the report has been delivered.
final class GladiaLiveFailureReportTests: XCTestCase {
    func testAFinishJoiningWhileTheReportIsHeldReturnsOnlyAfterIt() async {
        let harness = GladiaHarness()
        let log = harness.log
        let client = harness.client
        let reporting = expectation(description: "onError is being delivered")
        let gate = DispatchSemaphore(value: 0)
        client.start(
            onTranscript: { log.transcript($0, isFinal: $1) },
            onError: { error in
                log.fail(error)
                reporting.fulfill()
                gate.wait()
                log.note("report-returned")
            }
        )
        let socket = openSession(harness)
        socket.final("Confirmed.", id: "00-01")
        DispatchQueue.global().async { socket.failReceive() }
        await fulfillment(of: [reporting], timeout: 5)
        XCTAssertEqual(client.currentStage, .closed, "The run is terminal before its report returns")

        let finish = Task { () -> String? in
            let transcript = await client.finishAndWait()
            log.note("finish-returned")
            return transcript
        }
        await waitUntil("the late finish to park behind the report") { client.finishWaiterCount == 1 }
        XCTAssertFalse(log.timeline.contains("finish-returned"), "No finish may return before onError has")
        gate.signal()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(log.timeline, ["final:Confirmed.", "error", "report-returned", "finish-returned"])
        XCTAssertEqual(log.errors.first as? GladiaStreamingError, .connectionLost)
    }

    func testAFinishJoiningWhileTheSocketCancelIsHeldReturnsOnlyAfterTheReport() async {
        let harness = GladiaHarness()
        let log = harness.log
        let client = harness.client
        harness.start()
        let socket = openSession(harness)
        socket.final("Confirmed.", id: "00-01")
        let cancelling = expectation(description: "The failed run's socket is being cancelled")
        let gate = DispatchSemaphore(value: 0)
        socket.holdNextCancel(entered: { cancelling.fulfill() }, until: gate)
        DispatchQueue.global().async { socket.emit(#"{"type":"error","error":{"message":"Upstream failure"}}"#) }
        await fulfillment(of: [cancelling], timeout: 5)
        XCTAssertEqual(client.currentStage, .closed)
        XCTAssertTrue(log.errors.isEmpty, "The report follows the cancel")

        let finish = Task { () -> String? in
            let transcript = await client.finishAndWait()
            log.note("finish-returned")
            return transcript
        }
        await waitUntil("the late finish to park behind the report") { client.finishWaiterCount == 1 }
        XCTAssertFalse(log.timeline.contains("finish-returned"))
        gate.signal()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(log.timeline, ["final:Confirmed.", "error", "finish-returned"])
        XCTAssertEqual(log.errors.first as? GladiaStreamingError, .server(message: "Upstream failure"))
    }

    func testRegisteredAndLateFinishesWaitForAReportWhoseHandlerRestarts() async throws {
        let harness = GladiaHarness()
        let log = harness.log
        let client = harness.client
        let replacementLog = GladiaEventLog()
        let reporting = expectation(description: "onError is being delivered")
        let gate = DispatchSemaphore(value: 0)
        client.start(
            onTranscript: { log.transcript($0, isFinal: $1) },
            onError: { error in
                log.fail(error)
                reporting.fulfill()
                gate.wait()
                client.start(
                    onTranscript: { replacementLog.transcript($0, isFinal: $1) },
                    onError: { replacementLog.fail($0) }
                )
                log.note("report-returned")
            }
        )
        let socket = openSession(harness)
        socket.final("First run.", id: "00-01")
        let registered = await finishTask(harness, note: "registered-returned")
        socket.completeSend()
        DispatchQueue.global().async { socket.failReceive() }
        await fulfillment(of: [reporting], timeout: 5)

        let late = Task { () -> String? in
            let transcript = await client.finishAndWait()
            log.note("late-returned")
            return transcript
        }
        await waitUntil("both finishes to park behind the report") { client.finishWaiterCount == 2 }
        XCTAssertFalse(log.timeline.contains { $0.hasSuffix("-returned") })
        gate.signal()
        let registeredResult = await registered.value
        let lateResult = await late.value
        XCTAssertEqual(registeredResult, "First run.")
        XCTAssertEqual(lateResult, "First run.")
        XCTAssertEqual(Array(log.timeline.prefix(3)), ["final:First run.", "error", "report-returned"])
        XCTAssertEqual(Set(log.timeline.dropFirst(3)), ["registered-returned", "late-returned"])

        let replacement = try XCTUnwrap(harness.sessions.requests.last)
        XCTAssertEqual(harness.sessions.requests.count, 2)
        XCTAssertEqual(replacement.cancelCount, 0, "Nothing from the failed run cleans up its replacement")
        XCTAssertEqual(client.currentStage, .initiating)
        XCTAssertEqual(client.finishWaiterCount, 0, "The old waiters never move to the replacement")
        socket.final("Stale.", id: "00-02")
        harness.clock.advance(by: GladiaLive.finishBudget)
        XCTAssertTrue(replacementLog.transcripts.isEmpty)
        XCTAssertTrue(replacementLog.errors.isEmpty, "Old deadlines cannot fail the replacement")
        client.cancel()
    }

    func testAFailureDuringATranscriptCallbackIsReportedAfterItWithoutBlockingTheCaller() async {
        let harness = GladiaHarness()
        let log = harness.log
        let client = harness.client
        let delivering = expectation(description: "A final is being delivered")
        let gate = DispatchSemaphore(value: 0)
        let reported = expectation(description: "The failure is reported")
        client.start(
            onTranscript: { text, isFinal in
                log.transcript(text, isFinal: isFinal)
                guard isFinal else { return }
                delivering.fulfill()
                gate.wait()
                log.note("final-returned")
            },
            onError: { error in
                log.fail(error)
                reported.fulfill()
            }
        )
        let socket = openSession(harness)
        DispatchQueue.global().async { socket.final("Confirmed first.", id: "00-01") }
        await fulfillment(of: [delivering], timeout: 5)

        client.sendAudio(Data([1, 2, 3]))
        XCTAssertEqual(client.currentStage, .closed, "The partial sample retired the run")
        XCTAssertTrue(log.errors.isEmpty, "The capture caller returns without delivering the report")
        gate.signal()
        await fulfillment(of: [reported], timeout: 5)
        XCTAssertEqual(log.timeline, ["final:Confirmed first.", "final-returned", "error"])
        XCTAssertEqual(log.errors.first as? GladiaStreamingError, .invalidPCM)
        let transcript = await client.finishAndWait()
        XCTAssertEqual(transcript, "Confirmed first.")
    }

    /// The session reply, handshake and one completed 100 ms frame.
    private func openSession(_ harness: GladiaHarness) -> GladiaFakeSocket {
        harness.sessions.grant()
        let socket = harness.socket
        socket.open()
        harness.client.sendAudio(GladiaHarness.pcm(0))
        socket.completeSend()
        return socket
    }

    /// A finish registered on the live run, which records `note` on return.
    private func finishTask(_ harness: GladiaHarness, note: String) async -> Task<String?, Never> {
        let armed = expectation(description: "Finish armed its deadline")
        harness.clock.whenScheduled(GladiaLive.finishBudget) { armed.fulfill() }
        let client = harness.client
        let log = harness.log
        let task = Task { () -> String? in
            let transcript = await client.finishAndWait()
            log.note(note)
            return transcript
        }
        await fulfillment(of: [armed], timeout: 5)
        return task
    }
}
