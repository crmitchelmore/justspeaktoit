import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import XCTest
@testable import SpeakWindowsPlatform

final class WinHTTPEventsTests: XCTestCase {
    func testCompleteTextAndBinaryMessagesKeepFIFOAndExactBytes() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        let messages: [StreamingWebSocketMessage] = [
            .text("Café 👩🏽‍💻\n"), .binary(Data([0, 255, 1, 128])), .text(""),
            .binary(Data(repeating: 213, count: 100_000))
        ]
        messages.forEach { events.message($0) }
        messages.forEach { _ in events.receive { probe.received($0) } }
        XCTAssertEqual(probe.messages, messages)
        XCTAssertEqual(probe.failures.count, 0)
    }

    func testPeerCloseDrainsBufferedMessagesBeforeReturningCloseCode() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        events.message(.text("Last words."))
        events.message(.binary(Data([1, 2])))
        events.fail(WinHTTPWebSocketError("Normal close", closeCode: 1000))
        for _ in 0..<3 { events.receive { probe.received($0) } }
        XCTAssertEqual(probe.messages, [.text("Last words."), .binary(Data([1, 2]))])
        XCTAssertEqual(probe.failures.count, 1)
        XCTAssertEqual((probe.failures.first as? WinHTTPWebSocketError)?.closeCode, 1000)
    }

    func testCancellationDiscardsBufferedMessagesAndRejectsLaterOperations() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        events.message(.text("Do not deliver after cancellation"))
        events.fail(CancellationError(), discardPending: true)
        events.message(.binary(Data([1])))
        events.installOpen { probe.opened() }
        events.opened()
        events.receive { probe.received($0) }
        XCTAssertFalse(events.installSend { probe.sent($0) })
        XCTAssertTrue(probe.messages.isEmpty)
        XCTAssertEqual(probe.failures.count, 1)
        XCTAssertTrue(probe.failures.first is CancellationError)
        XCTAssertEqual(probe.sendResults, [false])
        XCTAssertEqual(probe.openCount, 0)
    }

    func testCancelAfterPeerCloseStillDiscardsUndeliveredMessages() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        events.message(.text("Buffered before peer close"))
        events.fail(WinHTTPWebSocketError("Normal close", closeCode: 1000))
        events.fail(CancellationError(), discardPending: true)
        events.receive { probe.received($0) }
        XCTAssertTrue(probe.messages.isEmpty)
        XCTAssertEqual(probe.failures.count, 1)
    }

    func testExactlyFourMiBIsAcceptedAndDequeueReleasesByteBudget() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        let message = StreamingWebSocketMessage.binary(Data(repeating: 37, count: 4 * 1_024 * 1_024))
        for _ in 0..<2 {
            events.message(message)
            events.receive { probe.received($0) }
        }
        XCTAssertEqual(probe.messages, [message, message])
        XCTAssertTrue(probe.failures.isEmpty)
    }

    func testByteOverflowFailsVisiblyDiscardsQueueAndAbortsOnce() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        events.installAbort { probe.aborted() }
        events.message(.binary(Data(repeating: 0, count: 4 * 1_024 * 1_024)))
        events.message(.binary(Data([1])))
        events.message(.text("late"))
        events.receive { probe.received($0) }
        events.fail(CancellationError(), discardPending: true)
        XCTAssertTrue(probe.messages.isEmpty)
        XCTAssertEqual(probe.failures.count, 1)
        XCTAssertEqual(probe.abortCount, 1)
    }

    func testTextQueueBudgetCountsUTF8BytesRatherThanCharacters() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        events.message(.binary(Data(repeating: 0, count: 4 * 1_024 * 1_024 - 3)))
        events.message(.text("💬"))
        events.receive { probe.received($0) }
        XCTAssertTrue(probe.messages.isEmpty)
        XCTAssertEqual(probe.failures.count, 1)
    }

    func testSixtyFourEmptyMessagesAreAcceptedButSixtyFifthFails() {
        let accepted = WinHTTPEvents()
        let acceptedProbe = WinHTTPEventProbe()
        for _ in 0..<64 { accepted.message(.text("")) }
        for _ in 0..<64 { accepted.receive { acceptedProbe.received($0) } }
        XCTAssertEqual(acceptedProbe.messages.count, 64)
        XCTAssertTrue(acceptedProbe.failures.isEmpty)
        let overflowing = WinHTTPEvents()
        let rejectedProbe = WinHTTPEventProbe()
        for _ in 0..<65 { overflowing.message(.text("")) }
        overflowing.receive { rejectedProbe.received($0) }
        XCTAssertTrue(rejectedProbe.messages.isEmpty)
        XCTAssertEqual(rejectedProbe.failures.count, 1)
    }

    func testOverlappingSendRejectsSecondWithoutReplacingFirstCompletion() {
        let events = WinHTTPEvents()
        let original = WinHTTPEventProbe()
        let overlapping = WinHTTPEventProbe()
        XCTAssertTrue(events.installSend { original.sent($0) })
        XCTAssertFalse(events.installSend { overlapping.sent($0) })
        XCTAssertTrue(original.sendResults.isEmpty)
        XCTAssertEqual(overlapping.sendResults, [false])
        events.sent(nil)
        events.sent(nil)
        events.fail(CancellationError())
        XCTAssertEqual(original.sendResults, [true])
    }

    func testOverlappingReceiveRejectsSecondWithoutReplacingFirstReceiver() {
        let events = WinHTTPEvents()
        let original = WinHTTPEventProbe()
        let overlapping = WinHTTPEventProbe()
        events.receive { original.received($0) }
        events.receive { overlapping.received($0) }
        XCTAssertEqual(overlapping.failures.count, 1)
        XCTAssertTrue(original.failures.isEmpty)
        events.message(.text("For first receiver"))
        XCTAssertEqual(original.messages, [.text("For first receiver")])
        XCTAssertTrue(overlapping.messages.isEmpty)
    }

    func testTerminalFailureCompletesPendingSendReceiveAndAbortExactlyOnce() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        events.installAbort { probe.aborted() }
        events.receive { probe.received($0) }
        XCTAssertTrue(events.installSend { probe.sent($0) })
        events.fail(CancellationError(), discardPending: true)
        events.fail(CancellationError(), discardPending: true)
        events.sent(nil)
        events.message(.text("late"))
        XCTAssertEqual(probe.failures.count, 1)
        XCTAssertEqual(probe.sendResults, [false])
        XCTAssertEqual(probe.abortCount, 1)
        XCTAssertTrue(probe.messages.isEmpty)
    }

    func testOpenCallbackRunsOnlyOnceAndCannotRunAfterFailure() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        events.installOpen { probe.opened() }
        events.opened()
        events.opened()
        events.fail(CancellationError())
        events.installOpen { probe.opened() }
        events.opened()
        XCTAssertEqual(probe.openCount, 1)
    }

    func testCallbacksCanReenterForOpenReceiveSendAndCancellation() {
        let events = WinHTTPEvents()
        let probe = WinHTTPEventProbe()
        let completed = expectation(description: "All callbacks run outside the event lock")
        DispatchQueue.global().async {
            events.installAbort { events.fail(CancellationError()); probe.aborted() }
            events.installOpen {
                probe.opened()
                events.receive { first in
                    probe.received(first)
                    events.receive { probe.received($0) }
                }
            }
            events.opened()
            events.message(.text("first"))
            events.message(.text("second"))
            XCTAssertTrue(events.installSend { error in
                probe.sent(error)
                XCTAssertTrue(events.installSend { probe.sent($0) })
            })
            events.sent(nil)
            events.sent(nil)
            events.receive { result in probe.received(result); events.fail(CancellationError()) }
            events.fail(CancellationError())
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(probe.messages, [.text("first"), .text("second")])
        XCTAssertEqual(probe.sendResults, [true, true])
        XCTAssertEqual(probe.failures.count, 1)
        XCTAssertEqual(probe.openCount, 1)
        XCTAssertEqual(probe.abortCount, 1)
    }

    func testSendCompletionRacingCancellationIsDeliveredExactlyOnce() {
        for _ in 0..<100 {
            let events = WinHTTPEvents()
            let probe = WinHTTPEventProbe()
            XCTAssertTrue(events.installSend { probe.sent($0) })
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) { events.sent(nil) }
            DispatchQueue.global().async(group: group) { events.fail(CancellationError()) }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(probe.sendResults.count, 1)
        }
    }

    func testConnectionIsRefusedWithoutNativeStateWhileFailedReleasesAreOwned() throws {
        let releases = WinHTTPReleaseQueue(limit: 1, initialDelay: 60, maximumDelay: 60)
        releases.release { false }
        let deadline = Date().addingTimeInterval(5)
        while releases.outstanding == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(releases.outstanding, 1)
        let request = URLRequest(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9/refused")))
        let connection = WinHTTPStreamingConnection(request: request, releases: releases)
        let probe = WinHTTPEventProbe()
        connection.resume { probe.opened() }
        connection.receive { probe.received($0) }
        connection.send(.text("not sent")) { probe.sent($0) }
        XCTAssertEqual(probe.openCount, 0)
        XCTAssertEqual(probe.sendResults, [false])
        let error = try XCTUnwrap(probe.failures.first as? WinHTTPWebSocketError)
        XCTAssertTrue(error.message.contains("still closing"), error.message)
        connection.cancel()
    }
}

private final class WinHTTPEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var messageValues: [StreamingWebSocketMessage] = []
    private var failureValues: [Error] = []
    private var sendValues: [Bool] = []
    private var opens = 0
    private var aborts = 0
    var messages: [StreamingWebSocketMessage] { lock.withLock { messageValues } }
    var failures: [Error] { lock.withLock { failureValues } }
    var sendResults: [Bool] { lock.withLock { sendValues } }
    var openCount: Int { lock.withLock { opens } }
    var abortCount: Int { lock.withLock { aborts } }

    func received(_ result: Result<StreamingWebSocketMessage, Error>) {
        lock.withLock {
            switch result {
            case .success(let message): messageValues.append(message)
            case .failure(let error): failureValues.append(error)
            }
        }
    }
    func sent(_ error: Error?) { lock.withLock { sendValues.append(error == nil) } }
    func opened() { lock.withLock { opens += 1 } }
    func aborted() { lock.withLock { aborts += 1 } }
}
