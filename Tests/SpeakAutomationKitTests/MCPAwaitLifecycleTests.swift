import Foundation
#if canImport(Darwin)
import Darwin
#endif
import SpeakCore
import XCTest
@testable import SpeakAutomationKit

#if canImport(Darwin)
final class MCPAwaitLifecycleTests: XCTestCase {
    private func line(_ id: Int, tool: String = "await_transcript") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": tool,
                "arguments": tool == "await_transcript" ? ["capture_id": UUID().uuidString] : [:]]])
    }

    func testPendingAwait_AllowsStatusStopAndCancellationOnSameStdioStream() async throws {
        let entered = expectation(description: "await transport entered")
        let returned = expectation(description: "await worker transport returned")
        let served = expectation(description: "stdio EOF returned")
        let client = HeldMCPAwaitClient(entered: { entered.fulfill() }, returned: { returned.fulfill() })
        let input = Pipe()
        let output = Pipe()
        let server = MCPStdioServer(handler: .init(client: client, version: "fixture"),
                                    input: input.fileHandleForReading, output: output.fileHandleForWriting)
        DispatchQueue.global().async { server.serve(); served.fulfill() }
        var awaitLine = try self.line(1)
        awaitLine.append(0x0A)
        input.fileHandleForWriting.write(awaitLine)
        await fulfillment(of: [entered], timeout: 2)
        var following = try self.line(2, tool: "status")
        following.append(0x0A)
        following.append(try self.line(3, tool: "stop_dictation"))
        following.append(0x0A)
        following.append(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8))
        following.append(0x0A)
        input.fileHandleForWriting.write(following)
        await fulfillment(of: [returned], timeout: 2)
        input.fileHandleForWriting.closeFile()
        await fulfillment(of: [served], timeout: 2)
        output.fileHandleForWriting.closeFile()
        let responses = output.fileHandleForReading.readDataToEndOfFile().split(separator: 0x0A)
        let objects = try responses.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertTrue(objects.contains { $0["id"] as? Int == 2 })
        XCTAssertTrue(objects.contains { $0["id"] as? Int == 3 })
        XCTAssertEqual(client.legacyCommands, [.status, .stopDictation])
    }

    func testInvalidRawAwaitIDs_NeverInvokeClientOrEnterSynchronousFallback() throws {
        let sink = MCPTestOutput()
        let count = MCPInvocationCount()
        let client = ImmediateMCPAwaitClient(entered: { count.increment() })
        let handler = MCPRequestHandler(client: client, version: "fixture")
        let dispatcher = MCPStdioDispatch(handler: handler, writeData: sink.write)
        let identifiers = ["true", "null", #"{"nested":1}"#, "1.25", "1.2500000000000001",
                           "0.1", "0.10000000000000001"]
        for rawID in identifiers {
            // Preserve the original numeric token; JSONSerialization would round the precision pair.
            let data = Data("""
                {"jsonrpc":"2.0","id":\(rawID),"method":"tools/call",
                "params":{"name":"await_transcript","arguments":{"capture_id":"\(UUID().uuidString)"}}}
                """.utf8)
            dispatcher.dispatch(data)
            let line = try XCTUnwrap(String(data: data, encoding: .utf8))
            let response = try XCTUnwrap(handler.handle(line: line))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            XCTAssertNotNil(object["error"])
        }
        dispatcher.close()
        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(sink.lines.count, identifiers.count)
        XCTAssertNil(MCPRequestHandler.awaitIdentity(in: Data(#"{"id":true}"#.utf8)))
    }

    func testAwaitHandler_UsesCompleteTypedSocketIdentityAndStableRetries() throws {
        let client = CapturingMCPAwaitClient()
        let handler = MCPRequestHandler(client: client, version: "fixture")
        let prefix = String(repeating: "a", count: 512)
        let identifiers: [Any] = [1, "1", prefix + "first", prefix + "second", 1]
        let capture = UUID().uuidString
        for id in identifiers {
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
                "method": "tools/call", "params": ["name": "await_transcript",
                    "arguments": ["capture_id": capture]]])
            let line = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertNotNil(handler.handle(line: line))
        }
        let ids = client.identifiers
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(Set(ids.prefix(4)).count, 4)
        XCTAssertEqual(ids.first, ids.last)
        XCTAssertTrue(ids.allSatisfy { $0.count <= AutomationLimits.maxIdentifierLength })
    }

    func testEOF_CancelsAwaitAndNoWorkerOutputAfterCloseReturns() async throws {
        let entered = expectation(description: "await started")
        let returned = expectation(description: "owned transport cancellation returned")
        let client = HeldMCPAwaitClient(entered: { entered.fulfill() }, returned: { returned.fulfill() })
        let sink = MCPTestOutput()
        let dispatcher = MCPStdioDispatch(handler: .init(client: client, version: "fixture"), writeData: sink.write)
        dispatcher.dispatch(try self.line(1))
        await fulfillment(of: [entered], timeout: 2)
        dispatcher.close()
        await fulfillment(of: [returned], timeout: 2)
        dispatcher.dispatch(try self.line(2, tool: "stop_dictation"))
        XCTAssertTrue(sink.lines.isEmpty)
        XCTAssertTrue(client.legacyCommands.isEmpty, "Closed output must never dispatch further mutations")
    }

    func testOutputBoundary_CloseWaitsForAdmittedWriteAndRejectsLaterWrites() async {
        let entered = expectation(description: "actual writer entered")
        let observedClose = expectation(description: "writer observed closed while retaining boundary")
        let didClose = expectation(description: "close returned")
        let returned = MCPClosedFlag()
        let sink = MCPHeldOutput(entered: { entered.fulfill() }, observedClose: { observedClose.fulfill() })
        let dispatcher = MCPStdioDispatch(handler: .init(client: EmptyMCPClient(), version: "fixture"),
                                          writeData: sink.write)
        defer { sink.release() }
        DispatchQueue.global().async { dispatcher.write("{\"id\":1}") }
        await fulfillment(of: [entered], timeout: 2)
        DispatchQueue.global().async { dispatcher.close(); returned.close(); didClose.fulfill() }
        await fulfillment(of: [observedClose], timeout: 2)
        XCTAssertFalse(returned.value, "close must not return while the admitted writer owns its boundary")
        sink.release()
        await fulfillment(of: [didClose], timeout: 2)
        dispatcher.write("{\"id\":2}")
        XCTAssertEqual(sink.count, 1)
    }

    func testOutputWrites_AreSerializedWholeJSONLines() throws {
        let sink = MCPTestOutput()
        let dispatcher = MCPStdioDispatch(handler: .init(client: EmptyMCPClient(), version: "fixture"),
                                          writeData: sink.write)
        DispatchQueue.concurrentPerform(iterations: 100) { dispatcher.write("{\"id\":\($0)}") }
        dispatcher.close()
        XCTAssertEqual(sink.lines.count, 100)
        for line in sink.lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: line)) }
    }

    func testSixteenAwaitWorkersRemainAdmittedThroughOutputCleanup() async throws {
        let entered = expectation(description: "all transports returned")
        entered.expectedFulfillmentCount = 16
        let writing = expectation(description: "first response owns output boundary")
        let sink = MCPHeldOutput(entered: { writing.fulfill() })
        let client = ImmediateMCPAwaitClient(entered: { entered.fulfill() })
        let dispatcher = MCPStdioDispatch(handler: .init(client: client, version: "fixture"), writeData: sink.write)
        defer { sink.release(); dispatcher.close() }
        for id in 0..<16 { dispatcher.dispatch(try self.line(id)) }
        await fulfillment(of: [entered, writing], timeout: 2)
        XCTAssertEqual(dispatcher.activeAwaitWorkerCount, 16,
                       "Transport return must not release admission while responses wait on blocked output")
        sink.release()
    }

    #if canImport(Darwin)
    func testRealBlockedPipeWrite_EOFInterruptsAndOriginalFlagsRestore() async throws {
        let pipe = Pipe()
        let original = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFL)
        let writer = MCPBoundedOutput(output: pipe.fileHandleForWriting)
        let state = MCPClosedFlag()
        let entered = expectation(description: "writer observed real full-pipe backpressure")
        let ended = expectation(description: "writer ended after EOF")
        DispatchQueue.global().async {
            let completed = writer.write(Data(repeating: 0x61, count: 4 * 1024 * 1024),
                                         isClosed: { state.value }, didBackpressure: { entered.fulfill() })
            XCTAssertFalse(completed)
            ended.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        state.close()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFL), original)
    }
    #endif
}

#endif

private struct EmptyMCPClient: AutomationRequesting {
    func send(_ request: AutomationRequest) throws -> AutomationResponse {
        .success(id: request.id, command: request.command, result: .init())
    }
}

private final class HeldMCPAwaitClient: CancellableAutomationRequesting, @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled: Set<String> = []
    private var commands: [AutomationCommand] = []
    private let entered: () -> Void
    private let returned: () -> Void
    init(entered: @escaping () -> Void, returned: @escaping () -> Void) {
        self.entered = entered
        self.returned = returned
    }
    var legacyCommands: [AutomationCommand] { self.condition.withLock { self.commands } }
    func send(_ request: AutomationRequest) throws -> AutomationResponse {
        self.condition.withLock { self.commands.append(request.command) }
        return .success(id: request.id, command: request.command, result: .init())
    }
    func send(_ request: AutomationRequest, cancellation: AutomationRequestCancellation) throws -> AutomationResponse {
        cancellation.install { [self] in
            self.condition.withLock {
                self.cancelled.insert(request.id)
                self.condition.broadcast()
            }
        }
        defer { cancellation.uninstall(); self.returned() }
        self.entered()
        self.condition.lock()
        let deadline = Date().addingTimeInterval(3)
        while !self.cancelled.contains(request.id) {
            if !self.condition.wait(until: deadline) { break }
        }
        let cancelled = self.cancelled.contains(request.id)
        self.condition.unlock()
        guard cancelled else {
            throw AutomationError(code: .timedOut, message: "Fixture wait expired without owned cancellation.")
        }
        throw AutomationError(code: .appUnavailable, message: "Fixture request cancelled.")
    }
}

private final class MCPTestOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data] = []
    var lines: [Data] { self.lock.withLock { self.data } }
    func write(_ data: Data, _ isClosed: () -> Bool) -> Bool {
        self.lock.withLock { self.data.append(data) }
        return true
    }
}

private final class MCPHeldOutput: @unchecked Sendable {
    private let condition = NSCondition()
    private let entered: () -> Void
    private let observedClose: () -> Void
    private var released = false
    private var writes = 0
    private var enteredOnce = false
    private var reportedClose = false
    var count: Int { self.condition.withLock { self.writes } }
    init(entered: @escaping () -> Void, observedClose: @escaping () -> Void = {}) {
        self.entered = entered
        self.observedClose = observedClose
    }
    func write(_ data: Data, _ isClosed: () -> Bool) -> Bool {
        self.condition.lock()
        if !self.enteredOnce { self.enteredOnce = true; self.entered() }
        let deadline = Date().addingTimeInterval(2)
        while !self.released, Date() < deadline {
            if !self.reportedClose, isClosed() { self.reportedClose = true; self.observedClose() }
            _ = self.condition.wait(until: Date().addingTimeInterval(0.01))
        }
        self.writes += 1
        self.condition.unlock()
        return true
    }
    func release() { self.condition.withLock { self.released = true; self.condition.broadcast() } }
}

private final class MCPClosedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    var value: Bool { self.lock.withLock { self.closed } }
    func close() { self.lock.withLock { self.closed = true } }
}

private struct ImmediateMCPAwaitClient: CancellableAutomationRequesting {
    let entered: @Sendable () -> Void
    func send(_ request: AutomationRequest) throws -> AutomationResponse {
        .success(id: request.id, command: request.command, result: .init())
    }
    func send(_ request: AutomationRequest, cancellation: AutomationRequestCancellation) throws -> AutomationResponse {
        self.entered()
        return try self.send(request)
    }
}

private final class MCPInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { self.lock.withLock { self.count } }
    func increment() { self.lock.withLock { self.count += 1 } }
}

private final class CapturingMCPAwaitClient: CancellableAutomationRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var identifiers: [String] { self.lock.withLock { self.ids } }
    func send(_ request: AutomationRequest) throws -> AutomationResponse {
        .success(id: request.id, command: request.command, result: .init())
    }
    func send(_ request: AutomationRequest, cancellation: AutomationRequestCancellation) throws -> AutomationResponse {
        self.lock.withLock { self.ids.append(request.id) }
        return try self.send(request)
    }
}
