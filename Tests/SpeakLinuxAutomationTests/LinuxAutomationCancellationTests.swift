import CLinuxAutomation
import Foundation
import Glibc
import SpeakAutomationKit
import SpeakCore
import XCTest

/// The production native listener and client over private throwaway sockets. The
/// fixture accepts and holds connections without answering, so every client
/// exchange blocks in native IO until it is cancelled, disconnected or times out.
final class LinuxAutomationCancellationTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("automation.sock").path }
    private var listener: SilentAutomationListener!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/jsti-cancel-\(UUID().uuidString.prefix(12))")
        listener = try SilentAutomationListener(path: path)
    }

    override func tearDownWithError() throws {
        listener.release()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func awaitRequest() -> AutomationRequest {
        AutomationRequest(command: .awaitTranscript, timeout: 600, captureID: UUID().uuidString)
    }

    func testCancellation_InterruptsBlockedReadWithoutWaitingForTheDeadline() async throws {
        listener.acceptInBackground()
        let token = AutomationRequestCancellation()
        let client = UnixSocketAutomationClient(socketPath: path)
        let request = awaitRequest()
        async let outcome = linuxAutomationOffThread { () -> AutomationError? in
            do {
                _ = try client.send(request, cancellation: token)
                return nil
            } catch { return error as? AutomationError }
        }
        try listener.waitForConnections(1)
        let started = ContinuousClock.now
        token.cancel()
        let error = await outcome
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertEqual(error?.code, .appUnavailable)
        XCTAssertEqual(error?.message, "Automation request cancelled.")
        XCTAssertTrue(listener.peerClosed(0), "Cancellation must close the client's socket")
        token.cancel()
    }

    func testCancellation_InterruptsBlockedNativeWrite() async throws {
        listener.acceptInBackground()
        guard let signal = jsti_automation_cancel_create() else { return XCTFail("No cancellation token") }
        defer { jsti_automation_cancel_release(signal) }
        var connection: OpaquePointer?
        XCTAssertEqual(
            Int(jsti_automation_connect_cancellable(path, jsti_automation_deadline(60_000), signal, &connection)),
            JSTI_AUTOMATION_OK
        )
        let client = try XCTUnwrap(connection)
        defer { jsti_automation_close(client) }
        try listener.waitForConnections(1)
        let entered = expectation(description: "write is blocked by a peer that never reads")
        let owned = UncheckedSendable(client)
        async let status = linuxAutomationOffThread { () -> Int32 in
            // Far beyond the AF_UNIX send buffer, so the write must wait for the peer.
            let bytes = [UInt8](repeating: 7, count: 16 << 20)
            entered.fulfill()
            return bytes.withUnsafeBytes {
                jsti_automation_write(owned.value, $0.baseAddress, $0.count, jsti_automation_deadline(60_000))
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        let signalOwned = UncheckedSendable(signal)
        await linuxAutomationOffThread { jsti_automation_cancel_signal(signalOwned.value) }
        let result = await status
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertEqual(Int(result), JSTI_AUTOMATION_CANCELLED)
    }

    func testConnect_IsCancelledBeforeOpeningAndNeverPendsOnASaturatedListener() throws {
        guard let signal = jsti_automation_cancel_create() else { return XCTFail("No cancellation token") }
        defer { jsti_automation_cancel_release(signal) }
        jsti_automation_cancel_signal(signal)
        jsti_automation_cancel_signal(signal)
        var connection: OpaquePointer?
        XCTAssertEqual(
            Int(jsti_automation_connect_cancellable(path, jsti_automation_deadline(60_000), signal, &connection)),
            JSTI_AUTOMATION_CANCELLED
        )
        XCTAssertNil(connection)

        // Nobody accepts: Linux queues backlog + 1 connections, then refuses a
        // nonblocking AF_UNIX connect at once rather than leaving it pending.
        let pending = UnixSocketAutomationClient(socketPath: path)
        var held: [OpaquePointer] = []
        defer { held.forEach { jsti_automation_close($0) } }
        let started = ContinuousClock.now
        for _ in 0..<32 {
            var next: OpaquePointer?
            let status = jsti_automation_connect(path, jsti_automation_deadline(60_000), &next)
            guard Int(status) == JSTI_AUTOMATION_OK, let next else { break }
            held.append(next)
        }
        XCTAssertLessThan(held.count, 32, "The listener backlog must saturate")
        XCTAssertThrowsError(try pending.send(.init(command: .status, timeout: 600)))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testPeerEOF_EndsTheBlockedReadAsUnavailableNotCancelled() async throws {
        listener.acceptInBackground(closeImmediately: true)
        let token = AutomationRequestCancellation()
        let client = UnixSocketAutomationClient(socketPath: path)
        let request = awaitRequest()
        let started = ContinuousClock.now
        let error = await linuxAutomationOffThread { () -> AutomationError? in
            do {
                _ = try client.send(request, cancellation: token)
                return nil
            } catch { return error as? AutomationError }
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(error?.code, .appUnavailable)
        XCTAssertNotEqual(error?.message, "Automation request cancelled.")
        token.cancel()
    }

    func testLateReplyAfterCancellation_IsNeverDeliveredAndTheSendReturnsOnce() async throws {
        listener.acceptInBackground()
        let token = AutomationRequestCancellation()
        let client = UnixSocketAutomationClient(socketPath: path)
        let request = awaitRequest()
        let returns = LinuxAutomationReturnCount()
        async let outcome = linuxAutomationOffThread { () -> AutomationError? in
            defer { returns.increment() }
            do {
                _ = try client.send(request, cancellation: token)
                return nil
            } catch { return error as? AutomationError }
        }
        try listener.waitForConnections(1)
        token.cancel()
        let error = await outcome
        XCTAssertEqual(error?.message, "Automation request cancelled.")
        XCTAssertTrue(listener.peerClosed(0))
        let late = AutomationResponse.success(id: request.id, command: request.command, result: .init(text: "late"))
        XCTAssertFalse(listener.reply(0, with: late), "A reply after cancellation has no reader")
        token.cancel()
        XCTAssertEqual(returns.value, 1)
    }

    func testAwaitReplyForAnotherRequest_IsRejectedNotDelivered() throws {
        let server = LinuxAutomationServerFixture(listener: listener)
        server.answerOnce(replyID: "another-request")
        let token = AutomationRequestCancellation()
        XCTAssertThrowsError(
            try UnixSocketAutomationClient(socketPath: path).send(awaitRequest(), cancellation: token)
        ) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .unsupportedCommand)
        }
        try server.join()
    }

    func testCancelAfterReply_IsANoOpAndTheReplyStands() throws {
        let server = LinuxAutomationServerFixture(listener: listener)
        server.answerOnce()
        let token = AutomationRequestCancellation()
        let reply = try UnixSocketAutomationClient(socketPath: path).send(.init(command: .status), cancellation: token)
        token.cancel()
        token.cancel()
        XCTAssertTrue(reply.ok)
        try server.join()
    }
}

/// The production native listener; accepted connections stay open and unread
/// until the fixture is released, unless `closeImmediately` asks for peer EOF.
private final class SilentAutomationListener: @unchecked Sendable {
    let native: OpaquePointer
    private let condition = NSCondition()
    private var held: [OpaquePointer] = []
    private var accepted = 0
    private var thread: Thread?
    private let joined = DispatchSemaphore(value: 0)

    init(path: String) throws {
        var listener: OpaquePointer?
        try LinuxAutomationStream.check(jsti_automation_listen(path, &listener))
        native = try XCTUnwrap(listener)
    }

    func acceptInBackground(closeImmediately: Bool = false) {
        let thread = Thread { [self] in
            defer { joined.signal() }
            while true {
                var connection: OpaquePointer?
                let status = jsti_automation_accept(native, &connection)
                guard Int(status) == JSTI_AUTOMATION_OK, let connection else { return }
                condition.withLock {
                    if closeImmediately { jsti_automation_close(connection) } else { held.append(connection) }
                    accepted += 1
                    condition.broadcast()
                }
            }
        }
        self.thread = thread
        thread.start()
    }

    func waitForConnections(_ count: Int) throws {
        let deadline = Date().addingTimeInterval(2)
        try condition.withLock {
            while accepted < count {
                guard condition.wait(until: deadline) else {
                    throw AutomationError(code: .timedOut, message: "The fixture accepted no connection.")
                }
            }
        }
    }

    /// Drains a held connection until the client closes it: EOF proves the
    /// client's blocked worker returned and released its socket.
    func peerClosed(_ index: Int) -> Bool {
        guard let connection = condition.withLock({ held.indices.contains(index) ? held[index] : nil }) else {
            return false
        }
        var byte: UInt8 = 0
        let deadline = jsti_automation_deadline(2_000)
        while true {
            let status = jsti_automation_read(connection, &byte, 1, deadline)
            if Int(status) != JSTI_AUTOMATION_OK { return Int(status) == JSTI_AUTOMATION_UNAVAILABLE }
        }
    }

    /// Writes a framed reply to a held connection; false when the client is gone.
    func reply(_ index: Int, with response: AutomationResponse) -> Bool {
        guard let connection = condition.withLock({ held.indices.contains(index) ? held[index] : nil }),
              let frame = AutomationWireExchange.responseFrame(for: response) else { return false }
        let stream = LinuxAutomationStream(connection: connection, deadline: jsti_automation_deadline(2_000))
        return (try? stream.writeAll(frame)) != nil
    }

    func release() {
        jsti_automation_stop(native)
        if thread != nil { joined.wait() }
        condition.withLock {
            held.forEach { jsti_automation_close($0) }
            held = []
        }
        jsti_automation_release(native)
    }
}

/// Answers exactly one request over the same production listener.
private final class LinuxAutomationServerFixture: @unchecked Sendable {
    private let listener: SilentAutomationListener
    private let done = DispatchSemaphore(value: 0)
    private var failure: Error?

    init(listener: SilentAutomationListener) { self.listener = listener }

    func answerOnce(replyID: String? = nil) {
        Thread { [self] in
            defer { done.signal() }
            var connection: OpaquePointer?
            guard Int(jsti_automation_accept(listener.native, &connection)) == JSTI_AUTOMATION_OK, let connection else {
                failure = AutomationError(code: .internalError, message: "Fixture accept failed.")
                return
            }
            defer { jsti_automation_close(connection) }
            let stream = LinuxAutomationStream(connection: connection, deadline: jsti_automation_deadline(2_000))
            do {
                let request = try AutomationWireExchange.readRequest(from: stream)
                let reply = AutomationResponse.success(
                    id: replyID ?? request.id, command: request.command, result: .init()
                )
                try stream.writeAll(XCTUnwrap(AutomationWireExchange.responseFrame(for: reply)))
            } catch { failure = error }
        }.start()
    }

    func join() throws {
        guard done.wait(timeout: .now() + 2) == .success else {
            throw AutomationError(code: .timedOut, message: "Fixture did not finish.")
        }
        if let failure { throw failure }
    }
}

private final class LinuxAutomationReturnCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private func linuxAutomationOffThread<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
) async -> Value {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: operation()) }.start()
    }
}
