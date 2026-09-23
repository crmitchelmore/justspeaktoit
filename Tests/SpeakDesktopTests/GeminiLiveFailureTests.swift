import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Failure and cancellation: every word the server sent reaches the host
/// before the error, the error before any finish caller returns, and a
/// cancellation is never reported as a provider failure.
final class GeminiLiveFailureTests: XCTestCase {
    private typealias Fixture = GeminiLiveFixture

    func testConnectionClosedMidStreamIsReportedWithItsStatus() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Kept.")
        fixture.socket.interim("Maybe")
        fixture.socket.closeByPeer(code: 1_011)
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Kept.", final: true), .transcript("Maybe", final: false), .error("closed(code: 1011)")
        ])
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Kept.", "A later finish returns the confirmed text at once")
    }

    func testDroppedConnectionWithoutACloseFrameIsATransportFailure() {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.closeByPeer()
        XCTAssertEqual(fixture.log.entries, [GeminiEventLog.urlError(.networkConnectionLost)])
    }

    func testServerErrorDuringAFinishReleasesTheWithheldDraftBeforeTheError() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Live.")
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.socket.interim("Draft")
        fixture.socket.serverError(code: 500, status: "INTERNAL")
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Live.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Live.", final: true), .transcript("Draft", final: false),
            .error(#"server(code: Optional(500), status: Optional("INTERNAL"), message: "Synthetic failure")"#),
            .finished("Live.")
        ])
    }

    func testFinalsWithheldByAFinishAreReleasedInOrderWhenItFails() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.client.sendAudio(Fixture.frame(1))
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        fixture.socket.final("Withheld one.")
        fixture.socket.final("Withheld two.")
        fixture.socket.interim("Draft")
        fixture.socket.closeByPeer(code: 1_011)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Withheld one. Withheld two.")
        XCTAssertEqual(fixture.log.entries, [
            .transcript("Withheld one.", final: true), .transcript("Withheld two.", final: true),
            .transcript("Draft", final: false), .error("closed(code: 1011)"),
            .finished("Withheld one. Withheld two.")
        ])
    }

    /// The receive worker is handing a final to the host when the capture
    /// thread sends a partial sample. The capture call must not wait for the
    /// host, and the error must reach it only after that final.
    func testFailureWaitsForATranscriptTheHostIsStillReceiving() async throws {
        let factory = GeminiSocketFactory(), clock = GeminiTestClock(), log = GeminiEventLog()
        let client = GeminiLiveClient(
            apiKey: "synthetic-key", makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
        let release = DispatchSemaphore(value: 0)
        let receiving = expectation(description: "The final is on its way to the host")
        client.start(onTranscript: { text, isFinal in
            if isFinal {
                receiving.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success, "The held final was never released")
            }
            log.transcript(text, final: isFinal)
        }, onError: { log.fail($0) })
        let socket = factory.sockets[0]
        socket.open()
        socket.completeSend()
        socket.setupComplete()
        DispatchQueue.global().async { socket.final("Final words.") }
        await fulfillment(of: [receiving], timeout: 2)

        client.sendAudio(Data([1, 2, 3]))
        XCTAssertTrue(log.entries.isEmpty, "The error waits behind the final being delivered")
        release.signal()
        try await waitUntil { log.entries.count == 2 }
        XCTAssertEqual(log.entries, [.transcript("Final words.", final: true), .error("invalidPCM")])
    }

    /// A failure retires the run and is still cancelling its socket when a
    /// finish joins. The finish must wait for that error, not return first.
    func testFinishJoiningWhileAFailureIsDeliveredWaitsForTheError() async throws {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Confirmed.")
        let release = DispatchSemaphore(value: 0)
        let cancelling = expectation(description: "The failed run is cancelling its socket")
        fixture.socket.holdCancel(until: release) { cancelling.fulfill() }
        let socket = fixture.socket
        DispatchQueue.global().async { socket.serverError(code: 500, status: "INTERNAL") }
        await fulfillment(of: [cancelling], timeout: 2)

        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertFalse(fixture.log.entries.contains { if case .error = $0 { true } else { false } })
        release.signal()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(fixture.log.entries.suffix(2), [
            .error(#"server(code: Optional(500), status: Optional("INTERNAL"), message: "Synthetic failure")"#),
            .finished("Confirmed.")
        ])
    }

    func testStopDuringAFinishReturnsConfirmedTextWithoutAnError() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Kept.")
        let finish = await fixture.finishUntilStreamEnd(self)
        fixture.client.stop()
        fixture.client.stop()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.log.entries, [.transcript("Kept.", final: true), .finished("Kept.")])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testCancellingTheFinishingTaskEndsTheSessionPromptly() async {
        let fixture = Fixture()
        fixture.startReady()
        fixture.socket.final("Kept.")
        let finish = await fixture.finishUntilStreamEnd(self)
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertTrue(fixture.log.errors.isEmpty, "Cancellation is not a provider failure")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    /// Polls a condition within a bound; it never sleeps for an outcome.
    private func waitUntil(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition not reached", file: file, line: line)
    }
}

extension GeminiEventLog {
    static func urlError(_ code: URLError.Code) -> Entry { .error(describe(URLError(code))) }
}
