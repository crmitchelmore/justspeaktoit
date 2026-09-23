import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// A failure is published outside the state lock. Every finish caller of the
/// failed run, including one that joins after the run is retired but before
/// the error is out, must return only after the error has been delivered, and
/// nothing may reconnect or touch a replacement afterwards.
final class CartesiaLiveTerminalDeliveryTests: XCTestCase {
    private let serverFailure = CartesiaEventLog.Entry.error(
        #"server(statusCode: Optional(500), code: nil, message: "Synthetic failure")"#
    )

    func testFinishJoiningWhileTheFailedSocketIsCancelledReturnsOnlyAfterTheError() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let release = DispatchSemaphore(value: 0)
        let cancelling = expectation(description: "The failure retired the run and is cancelling its socket")
        fixture.socket.holdCancel(until: release) { cancelling.fulfill() }
        let socket = fixture.socket
        DispatchQueue.global().async { socket.serverError(status: 500) }
        await fulfillment(of: [cancelling], timeout: 2)
        XCTAssertTrue(fixture.log.errors.isEmpty, "The run is terminal but its error is not delivered yet")

        let finish = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertFalse(fixture.log.entries.contains(.finished("Confirmed.")), "The late finish must wait")
        release.signal()

        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(Array(fixture.log.entries.suffix(2)), [serverFailure, .finished("Confirmed.")])
        XCTAssertEqual(fixture.client.pendingFinishes, 0)
    }

    func testRegisteredAndLateFinishesBothReturnAfterTheErrorCallback() async {
        let fixture = CartesiaLiveFixture()
        let log = fixture.log, client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let delivering = expectation(description: "Error callback entered")
        client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { error in
            delivering.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            log.fail(error)
        })
        fixture.socket.open()
        fixture.socket.turn("Confirmed.")
        let closeSent = fixture.expectClose(self)
        let registered = fixture.finish()
        await fulfillment(of: [closeSent], timeout: 2)
        let socket = fixture.socket
        DispatchQueue.global().async { socket.serverError(status: 500) }
        await fulfillment(of: [delivering], timeout: 2)

        let late = fixture.finish()
        await fixture.waitForFinishes(1)
        XCTAssertFalse(log.entries.contains(.finished("Confirmed.")))
        release.signal()

        let results = await [registered.value, late.value]
        XCTAssertEqual(results, ["Confirmed.", "Confirmed."])
        XCTAssertEqual(Array(log.entries.suffix(3)), [
            serverFailure, .finished("Confirmed."), .finished("Confirmed.")
        ], "Both callers return after the error, never before it")
    }

    func testLateFinishOfAFailedRunIsIsolatedFromTheReplacementItsErrorStarts() async {
        let fixture = CartesiaLiveFixture()
        let log = fixture.log, client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let delivering = expectation(description: "Error callback entered")
        client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { error in
            delivering.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            log.fail(error)
            client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { log.fail($0) })
        })
        let old = fixture.socket
        old.open()
        old.turn("Old.")
        DispatchQueue.global().async { old.serverError(status: 500) }
        await fulfillment(of: [delivering], timeout: 2)
        let late = fixture.finish()
        await fixture.waitForFinishes(1)
        release.signal()

        let transcript = await late.value
        XCTAssertEqual(transcript, "Old.")
        // The late finish returns only after the error callback, which started the replacement.
        guard fixture.factory.sockets.count == 2 else {
            return XCTFail("The late finish returned before the error callback finished")
        }
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(replacement.cancels, 0, "Releasing the old run's callers must not touch the replacement")
        replacement.open()
        client.sendAudio(CartesiaLiveFixture.frame(1))
        old.turn("Stale.")
        replacement.turn("New.")
        XCTAssertEqual(replacement.binary.count, 1)
        XCTAssertEqual(
            Array(log.entries.suffix(2)), [.transcript("New.", final: false), .transcript("New.", final: true)]
        )
        XCTAssertFalse(log.entries.contains(.transcript("Stale.", final: true)))
        XCTAssertEqual(log.errors.count, 1)
        client.cancel()
    }

    func testCancellationWhileTheConnectionIsBuiltNeverOpensOrReconnects() async {
        let fixture = CartesiaLiveFixture()
        let client = fixture.client
        fixture.factory.configure { _ in client.cancel() }
        fixture.start()
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertEqual(fixture.socket.resumes, 0, "A run cancelled during construction never resumes its socket")
        XCTAssertFalse(fixture.socket.isReceiving)

        client.sendAudio(CartesiaLiveFixture.frame(1))
        let transcript = await client.finishAndWait()
        fixture.clock.fireAll()
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.factory.sockets.count, 1, "Nothing reconnects after cancellation")
        XCTAssertTrue(fixture.socket.sent.isEmpty)
        XCTAssertTrue(fixture.log.entries.isEmpty, "Cancellation is not an error")
    }

    func testNothingReconnectsAfterAFailureOrItsDeadlines() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(1))
        fixture.socket.serverError(status: 503)
        fixture.clock.fireAll()
        fixture.client.sendAudio(CartesiaLiveFixture.frame(2))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertNil(transcript)
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        XCTAssertEqual(fixture.socket.binary.count, 1)
        XCTAssertEqual(fixture.log.errors.count, 1)
    }
}
