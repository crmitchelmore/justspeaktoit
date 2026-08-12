import SpeakCore
import XCTest
@testable import SpeakAutomationKit

/// Behavioural coverage of the bundled MCP server: an agent's JSON-RPC session
/// in, newline-delimited JSON-RPC out.
final class MCPServerBehaviourTests: XCTestCase {
    private func handler(_ client: AutomationRequesting) -> MCPRequestHandler {
        MCPRequestHandler(client: client, version: "9.9.9")
    }

    private func respond(
        _ handler: MCPRequestHandler,
        _ message: [String: Any]
    ) throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let line = handler.handle(line: String(decoding: data, as: UTF8.self)) else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Handshake

    func testInitialize_advertisesToolsAndServerIdentity() throws {
        let response = try XCTUnwrap(self.respond(
            self.handler(StubAutomationClient(result: AutomationResult())),
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]]
        ))
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPRequestHandler.protocolVersion)
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "justspeaktoit")
        XCTAssertEqual(serverInfo["version"] as? String, "9.9.9")
        XCTAssertNotNil(result["capabilities"] as? [String: Any])
    }

    func testInitializedNotification_producesNoReply() {
        let handler = self.handler(StubAutomationClient(result: AutomationResult()))
        XCTAssertNil(handler.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testToolsList_exposesTheFourIssueTools() throws {
        let response = try XCTUnwrap(self.respond(
            self.handler(StubAutomationClient(result: AutomationResult())),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["transcribe_file", "get_history", "start_dictation", "stop_dictation"])

        let transcribe = try XCTUnwrap(tools.first { $0["name"] as? String == "transcribe_file" })
        let schema = try XCTUnwrap(transcribe["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["path"])
    }

    // MARK: - tools/call

    func testTranscribeFileTool_returnsTranscriptContentAndStructuredResult() throws {
        let client = StubAutomationClient(result: AutomationResult(text: "agent ready", model: "nova-3"))
        let response = try XCTUnwrap(self.respond(self.handler(client), [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "transcribe_file", "arguments": ["path": "/tmp/clip.m4a"]]
        ]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "agent ready")

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["text"] as? String, "agent ready")
        XCTAssertEqual(client.sentRequests.first?.command, .transcribeFile)
        XCTAssertEqual(client.sentRequests.first?.path, "/tmp/clip.m4a")
    }

    func testGetHistoryTool_passesBoundedLimit() throws {
        let client = StubAutomationClient(result: AutomationResult(entries: []))
        _ = try self.respond(self.handler(client), [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "get_history", "arguments": ["limit": 3]]
        ])
        XCTAssertEqual(client.sentRequests.first?.limit, 3)
    }

    func testGetHistoryTool_rejectsOutOfRangeLimitWithoutCallingTheApp() throws {
        let client = StubAutomationClient(result: AutomationResult())
        let response = try XCTUnwrap(self.respond(self.handler(client), [
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "get_history", "arguments": ["limit": 100_000]]
        ]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(client.sentRequests.isEmpty)
    }

    func testToolArgument_ofWrongType_isRejectedAsToolError() throws {
        let client = StubAutomationClient(result: AutomationResult())
        let response = try XCTUnwrap(self.respond(self.handler(client), [
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": ["name": "transcribe_file", "arguments": ["path": 42]]
        ]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String ?? "").contains("must be a string"))
        XCTAssertTrue(client.sentRequests.isEmpty)
    }

    func testStartDictation_isIdempotentPerCallID() throws {
        let client = StubAutomationClient(result: AutomationResult(sessionActive: true))
        let call: [String: Any] = [
            "jsonrpc": "2.0", "id": "abc", "method": "tools/call",
            "params": ["name": "start_dictation", "arguments": [:]]
        ]
        _ = try self.respond(self.handler(client), call)
        _ = try self.respond(self.handler(client), call)

        XCTAssertEqual(client.sentRequests.count, 2)
        XCTAssertEqual(
            client.sentRequests[0].id,
            client.sentRequests[1].id,
            "A retried call must reuse the idempotency key so the app can dedupe it"
        )
        XCTAssertEqual(client.sentRequests[0].id, "mcp-abc")
    }

    func testAppNotRunning_isReportedAsToolErrorNotProtocolError() throws {
        let client = StubAutomationClient(throwing: StubAutomationClient.unavailable)
        let response = try XCTUnwrap(self.respond(self.handler(client), [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "stop_dictation", "arguments": [:]]
        ]))
        XCTAssertNil(response["error"], "Agents should see a retryable tool result, not a broken session")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String ?? "").contains("app_unavailable"))
    }

    // MARK: - Malformed input

    func testMalformedJSON_returnsParseError() throws {
        let handler = self.handler(StubAutomationClient(result: AutomationResult()))
        let line = try XCTUnwrap(handler.handle(line: "{not json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    func testMissingMethod_returnsInvalidRequest() throws {
        let handler = self.handler(StubAutomationClient(result: AutomationResult()))
        let line = try XCTUnwrap(handler.handle(line: #"{"jsonrpc":"2.0","id":9}"#))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
    }

    func testUnknownMethod_returnsMethodNotFound() throws {
        let response = try XCTUnwrap(self.respond(
            self.handler(StubAutomationClient(result: AutomationResult())),
            ["jsonrpc": "2.0", "id": 10, "method": "resources/list"]
        ))
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testUnknownTool_returnsInvalidParams() throws {
        let response = try XCTUnwrap(self.respond(
            self.handler(StubAutomationClient(result: AutomationResult())),
            ["jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": ["name": "rm_rf"]]
        ))
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testBlankLine_isIgnored() {
        let handler = self.handler(StubAutomationClient(result: AutomationResult()))
        XCTAssertNil(handler.handle(line: "   "))
    }

    func testOversizedLine_isRejectedWithoutAllocatingAResponse() throws {
        let handler = self.handler(StubAutomationClient(result: AutomationResult()))
        let huge = String(repeating: "a", count: AutomationLimits.maxFrameBytes + 1)
        let line = try XCTUnwrap(handler.handle(line: huge))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
    }

    // MARK: - Framing

    func testStdioServer_framesOneJSONObjectPerLine() throws {
        let session = try self.runStdioSession(lines: [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        ])
        let lines = session.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "Notifications must not produce a reply")
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    /// Drives `MCPStdioServer` over real pipes, which is the only way to prove
    /// the newline framing works end to end.
    private func runStdioSession(lines: [String]) throws -> String {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let server = MCPStdioServer(
            handler: self.handler(StubAutomationClient(result: AutomationResult())),
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )

        let finished = expectation(description: "server finished")
        DispatchQueue.global().async {
            server.serve()
            try? outputPipe.fileHandleForWriting.close()
            finished.fulfill()
        }

        inputPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try inputPipe.fileHandleForWriting.close()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        wait(for: [finished], timeout: 5)
        return String(decoding: data, as: UTF8.self)
    }
}
