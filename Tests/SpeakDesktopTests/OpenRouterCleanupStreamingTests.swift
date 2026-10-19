import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class OpenRouterCleanupStreamingTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private let delta = #"data: {"choices":[{"index":0,"delta":{"content":"Héllo 👋"}}]}"# + "\n\n"
    private let terminal = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        + "\n\ndata: [DONE]\n\n"

    func testEveryByteSplit_PreservesUTF8AndSSEFraming() throws {
        let bytes = Array((delta + terminal).utf8)
        for split in 0...bytes.count {
            let parser = OpenRouterCleanupStream(onUpdate: { _ in })
            try parser.receive(Data(bytes.prefix(split)))
            try parser.receive(Data(bytes.dropFirst(split)))
            XCTAssertEqual(try parser.completedText(), "Héllo 👋")
        }
        let parser = OpenRouterCleanupStream(onUpdate: { _ in })
        for byte in bytes { try parser.receive(Data([byte])) }
        XCTAssertEqual(try parser.completedText(), "Héllo 👋")
    }

    func testCommentsMultilineCRLFAndUsage_AreFramedWithoutTextLoss() throws {
        let parser = OpenRouterCleanupStream(onUpdate: { _ in })
        let wire = ": keepalive\r\nevent: message\r\n"
            + "data: {\"choices\":\r\ndata: [{\"delta\":{\"content\":\"words\"}}]}\r\n\r\n"
            + terminal.replacingOccurrences(of: "data: [DONE]", with:
                "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":1}}\n\ndata: [DONE]")
        try parser.receive(Data(wire.utf8))
        XCTAssertEqual(try parser.completedText(), "words")
    }

    func testMalformedUTF8JSONAndProviderError_AreExplicitFailures() {
        let events = [
            Data([100, 97, 116, 97, 58, 32, 255, 10, 10]),
            Data("data: not-json\n\n".utf8),
            Data("data: {\"error\":{\"message\":\"refused\"}}\n\n".utf8),
            Data("data: {\"choices\":[{\"index\":1,\"delta\":{\"content\":\"wrong choice\"}}]}\n\n".utf8),
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"nul\\u0000text\"}}]}\n\n".utf8),
            Data("data: {\"choices\":[{},{}]}\n\n".utf8)
        ]
        for event in events {
            let parser = OpenRouterCleanupStream(onUpdate: { _ in })
            XCTAssertThrowsError(try parser.receive(event))
            XCTAssertThrowsError(try parser.completedText())
        }
    }

    func testMissingTerminalDoneAndEmptyResponses_NeverSucceed() throws {
        for wire in [delta, delta + "data: [DONE]\n\n", terminal,
                     delta + terminal.replacingOccurrences(of: "data: [DONE]\n\n", with: "")] {
            let parser = OpenRouterCleanupStream(onUpdate: { _ in })
            do {
                try parser.receive(Data(wire.utf8))
                XCTAssertThrowsError(try parser.completedText())
            } catch {
                XCTAssertTrue(error is ChatStreamingError)
            }
        }
    }

    func testLengthFilterAndLateContent_AreRejected() throws {
        for ending in [
            #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"# + "\n\n",
            terminal + delta,
            terminal + "data: [DONE]\n\n"
        ] {
            let parser = OpenRouterCleanupStream(onUpdate: { _ in })
            try parser.receive(Data(delta.utf8))
            XCTAssertThrowsError(try parser.receive(Data(ending.utf8)))
            XCTAssertThrowsError(try parser.completedText(), "A failed stream must remain failed")
        }
    }

    func testOversizedLineEventAndAccumulatedText_AreBounded() throws {
        let long = String(repeating: "a", count: OpenRouterCleanupStream.maximumEventBytes + 1)
        XCTAssertThrowsError(try OpenRouterCleanupStream(onUpdate: { _ in }).receive(Data(long.utf8)))
        let fields = String(repeating: "data: 1234567890\n", count: 7_000)
        XCTAssertThrowsError(try OpenRouterCleanupStream(onUpdate: { _ in }).receive(Data(fields.utf8)))
        let parser = OpenRouterCleanupStream(onUpdate: { _ in })
        let event = "data: {\"choices\":[{\"delta\":{\"content\":\""
            + String(repeating: "x", count: 32_768) + "\"}}]}\n\n"
        try parser.receive(Data(event.utf8))
        try parser.receive(Data(event.utf8))
        XCTAssertThrowsError(try parser.receive(Data(delta.utf8)))
    }

    func testStreamingRequest_UsesCanonicalWireAndReturnsOnlyCompletedText() async throws {
        let wire = delta + terminal
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, OpenRouterService.baseURL.appendingPathComponent("chat/completions"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            )
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual(body["model"] as? String, "test/model")
            XCTAssertEqual(body["temperature"] as? Double, 0.3)
            XCTAssertEqual(body["messages"] as? [[String: String]], [
                ["role": "system", "content": "Cleanup"], ["role": "user", "content": "raw"]
            ])
            return .respond(Self.response(request), Data(wire.utf8))
        }
        let seen = CleanupPreviewLog()
        let result = try await client().sendChatStreaming(
            systemPrompt: "Cleanup", messages: [.init(role: .user, content: "raw")],
            model: "test/model", temperature: 0.3, onUpdate: { seen.append($0) }
        )
        XCTAssertEqual(result.messages.map(\.content), ["Cleanup", "raw", "Héllo 👋"])
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(seen.values.last, "Héllo 👋")
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testPreviewArrivesBeforeHTTPCompletion_AndCancellationStopsOwnedTransport() async throws {
        let preview = expectation(description: "real incremental preview before EOF")
        let stopped = expectation(description: "owned transport cancelled")
        let wire = delta
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(Self.response(request), Data(wire.utf8))
        }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let client = client()
        let task = Task {
            try await client.sendChatStreaming(
                systemPrompt: nil, messages: [], model: "test/model", temperature: 0,
                onUpdate: { text in
                    XCTAssertEqual(text, "Héllo 👋")
                    preview.fulfill()
                }
            )
        }
        await fulfillment(of: [preview], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled stream succeeded") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testDeniedWrongContentTypeMalformedAndTruncatedTransport_DoNotRetry() async throws {
        for (status, mime, body) in [
            (401, "text/event-stream", delta),
            (200, "application/json", delta + terminal),
            (200, "text/event-stream", "data: broken\n\n"),
            (200, "text/event-stream", delta),
            (200, "text/event-stream", terminal)
        ] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                .respond(Self.response(request, status: status, mime: mime), Data(body.utf8))
            }
            do {
                _ = try await client().sendChatStreaming(
                    systemPrompt: nil, messages: [], model: "test/model", temperature: 0, onUpdate: { _ in }
                )
                XCTFail("Invalid or incomplete stream succeeded")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1, "Uncertain failures must not resend")
        }
    }

    func testMissingKeyAndPreCancelledCall_MakeNoRequest() async throws {
        do {
            _ = try await client(key: "").sendChatStreaming(
                systemPrompt: nil, messages: [], model: "test/model", temperature: 0, onUpdate: { _ in }
            )
            XCTFail("Missing credential accepted")
        } catch OpenRouterClientError.apiKeyMissing {}
        let client = client()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.sendChatStreaming(
                systemPrompt: nil, messages: [], model: "test/model", temperature: 0, onUpdate: { _ in }
            )
        }
        do { _ = try await task.value; XCTFail("Cancelled request accepted") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    private func client(key: String = "synthetic-key") -> OpenRouterChatClient {
        OpenRouterChatClient(apiKey: key, session: StubURLProtocol.makeSession())
    }

    private static func response(
        _ request: URLRequest, status: Int = 200, mime: String = "text/event-stream"
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": mime])!
    }
}

final class CleanupPreviewLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}
