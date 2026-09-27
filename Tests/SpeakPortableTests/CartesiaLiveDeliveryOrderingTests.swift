import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Work the client decides under its lock runs later, outside it. Two orders
/// must survive that gap: a frame claimed for a run never reaches a socket
/// after the run was cancelled or replaced, and a failure is never reported
/// ahead of a transcript the host is already being given.
final class CartesiaLiveDeliveryOrderingTests: XCTestCase {
    // MARK: Claimed frames and retired sockets

    func testAudioClaimedBeforeCancellationIsNeverHandedToTheCancelledSocket() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let claimed = expectation(description: "Frame claimed; its send deadline is being armed")
        fixture.clock.holdNextSchedule(of: CartesiaLiveClient.sendDeadline, until: release) { claimed.fulfill() }
        let returned = expectation(description: "The capture call returned")
        DispatchQueue.global().async {
            client.sendAudio(CartesiaLiveFixture.frame(1))
            returned.fulfill()
        }
        await fulfillment(of: [claimed], timeout: 2)
        client.cancel()
        XCTAssertEqual(fixture.socket.cancels, 1)
        release.signal()
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(fixture.socket.sent.count, 0, "A claimed frame never reaches the cancelled socket")
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    func testAudioClaimedBeforeReplacementReachesNeitherSocket() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let old = fixture.socket, client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let claimed = expectation(description: "Old frame claimed; its send deadline is being armed")
        fixture.clock.holdNextSchedule(of: CartesiaLiveClient.sendDeadline, until: release) { claimed.fulfill() }
        let returned = expectation(description: "The capture call returned")
        DispatchQueue.global().async {
            client.sendAudio(CartesiaLiveFixture.frame(1))
            returned.fulfill()
        }
        await fulfillment(of: [claimed], timeout: 2)
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        release.signal()
        await fulfillment(of: [returned], timeout: 2)
        client.sendAudio(CartesiaLiveFixture.frame(2))

        XCTAssertEqual(old.sent.count, 0, "The old run's frame never reaches its cancelled socket")
        XCTAssertEqual(replacement.binary, [CartesiaLiveFixture.frame(2)], "The replacement sends only its own audio")
        replacement.completeSend()
        fixture.clock.fireAll()
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertTrue(fixture.log.errors.isEmpty)
        client.cancel()
    }

    func testCloseClaimedBeforeCancellationIsNeverSent() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        fixture.socket.turn("Confirmed.")
        let release = DispatchSemaphore(value: 0)
        let claimed = expectation(description: "Close claimed; its send deadline is being armed")
        fixture.clock.holdNextSchedule(of: CartesiaLiveClient.sendDeadline, until: release) { claimed.fulfill() }
        let finish = fixture.finish()
        await fulfillment(of: [claimed], timeout: 2)
        fixture.client.cancel()
        release.signal()

        let transcript = await finish.value
        XCTAssertEqual(transcript, "Confirmed.")
        XCTAssertEqual(fixture.socket.sent.count, 0, "Cancellation leaves the claimed close unsent")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.log.errors.isEmpty)
    }

    func testCloseClaimedBeforeReplacementReachesNeitherSocket() async {
        let fixture = CartesiaLiveFixture()
        fixture.startAndOpen()
        let old = fixture.socket
        old.turn("Old.")
        let release = DispatchSemaphore(value: 0)
        let claimed = expectation(description: "Close claimed; its send deadline is being armed")
        fixture.clock.holdNextSchedule(of: CartesiaLiveClient.sendDeadline, until: release) { claimed.fulfill() }
        let finish = fixture.finish()
        await fulfillment(of: [claimed], timeout: 2)
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        release.signal()

        let transcript = await finish.value
        XCTAssertEqual(transcript, "Old.")
        XCTAssertEqual(old.sent.count, 0, "The old close never reaches its cancelled socket")
        XCTAssertEqual(replacement.sent.count, 0, "Nothing of the old run reaches the replacement")
        XCTAssertTrue(fixture.log.errors.isEmpty)
        fixture.client.cancel()
    }

    // MARK: Transcripts in delivery and failure reports

    func testFailureReportFollowsAFinalAlreadyBeingDelivered() async {
        let fixture = CartesiaLiveFixture()
        let log = fixture.log, client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let delivering = expectation(description: "A final is being delivered to the host")
        client.start(onTranscript: { text, isFinal in
            if isFinal {
                delivering.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            log.transcript(text, final: isFinal)
        }, onError: { log.fail($0) })
        let socket = fixture.socket
        socket.open()
        DispatchQueue.global().async { socket.turn("Final words.") }
        await fulfillment(of: [delivering], timeout: 2)

        let returned = expectation(description: "The capture call returned without waiting for the host")
        DispatchQueue.global().async {
            client.sendAudio(Data([1, 2, 3]))
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(socket.cancels, 1, "The failed run is retired at once")
        XCTAssertTrue(log.errors.isEmpty, "Its report waits behind the final already on its way to the host")

        let late = fixture.finish()
        await fixture.waitForFinishes(1)
        release.signal()
        let transcript = await late.value
        XCTAssertEqual(transcript, "Final words.")
        XCTAssertEqual(Array(log.entries.suffix(3)), [
            .transcript("Final words.", final: true), .error("invalidPCM"), .finished("Final words.")
        ])
    }

    func testReplacementStartedFromAHeldTranscriptIsIsolatedFromTheDeferredReport() async {
        let fixture = CartesiaLiveFixture()
        let log = fixture.log, client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let delivering = expectation(description: "The old run's final is being delivered to the host")
        client.start(onTranscript: { text, isFinal in
            log.transcript(text, final: isFinal)
            guard isFinal else { return }
            delivering.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            // The host starts again from inside the callback the failure waits behind.
            client.start(onTranscript: { log.transcript($0, final: $1) }, onError: { log.fail($0) })
        }, onError: { log.fail($0) })
        let old = fixture.socket
        old.open()
        DispatchQueue.global().async { old.turn("Old final.") }
        await fulfillment(of: [delivering], timeout: 2)
        client.sendAudio(Data([1, 2, 3]))
        XCTAssertEqual(old.cancels, 1, "The failed run is retired before any host callback re-enters")
        let late = fixture.finish()
        await fixture.waitForFinishes(1)
        release.signal()

        let transcript = await late.value
        XCTAssertEqual(transcript, "Old final.")
        guard fixture.factory.sockets.count == 2 else { return XCTFail("The replacement was never started") }
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(replacement.cancels, 0, "The old run's report cannot touch the replacement")
        replacement.open()
        client.sendAudio(CartesiaLiveFixture.frame(1))
        replacement.turn("New.")
        XCTAssertEqual(replacement.binary, [CartesiaLiveFixture.frame(1)])
        XCTAssertEqual(log.entries, [
            .transcript("Old final.", final: false), .transcript("Old final.", final: true),
            .error("invalidPCM"), .finished("Old final."),
            .transcript("New.", final: false), .transcript("New.", final: true)
        ])
        client.cancel()
    }

    func testRegisteredFinishAwaitsAFailureReportDeferredBehindADraft() async {
        let fixture = CartesiaLiveFixture()
        let log = fixture.log, client = fixture.client
        let release = DispatchSemaphore(value: 0)
        let delivering = expectation(description: "A draft is being delivered to the host")
        client.start(onTranscript: { text, isFinal in
            if !isFinal {
                delivering.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            log.transcript(text, final: isFinal)
        }, onError: { log.fail($0) })
        let socket = fixture.socket
        socket.open()
        client.sendAudio(CartesiaLiveFixture.frame(1))
        DispatchQueue.global().async {
            socket.turnStart()
            socket.turnUpdate("Draft")
        }
        await fulfillment(of: [delivering], timeout: 2)
        let finish = fixture.finish()
        await fixture.waitForFinishes(1)

        // The frame never completes; its deadline fails the run on this thread.
        fixture.clock.fire(CartesiaLiveClient.sendDeadline)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(log.errors.isEmpty, "The report waits behind the draft already on its way to the host")
        XCTAssertFalse(log.entries.contains(.finished(nil)), "The registered finish waits for the report")
        release.signal()

        let transcript = await finish.value
        XCTAssertNil(transcript)
        XCTAssertEqual(log.entries, [
            .transcript("Draft", final: false), .error("transportStalled(provider: \"Cartesia\")"), .finished(nil)
        ])
    }
}
