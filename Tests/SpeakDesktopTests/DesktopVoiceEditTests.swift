import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopVoiceEditTests: XCTestCase {
    func testRewrite_UsesTheSharedPromptEnvelopeModelAndTemperature() async throws {
        let client = EditChatSpy(messages: [.init(role: .assistant, content: "Shorter.")])
        let request = request(instruction: " make this shorter \n", temperature: 0.37)
        let result = try await DesktopVoiceEdit.rewrite(request, client: client)
        XCTAssertEqual(result, "Shorter.")
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls.first?.system, VoiceEditPolicy.systemPrompt)
        XCTAssertEqual(client.calls.first?.messages.map(\.role), [.user])
        XCTAssertEqual(client.calls.first?.messages.map(\.content), [
            VoiceEditPolicy.userMessage(selection: request.selection, instruction: "make this shorter")
        ])
        XCTAssertEqual(client.calls.first?.model, request.model)
        XCTAssertEqual(client.calls.first?.temperature, 0.37)
    }

    func testExplicitFormatting_IsPreservedByTheSharedPolicy() async throws {
        let reply = "```swift\nlet value = 1\n```"
        let client = EditChatSpy(messages: [.init(role: .assistant, content: reply)])
        let result = try await DesktopVoiceEdit.rewrite(
            request(instruction: "wrap the result in a Swift code fence"), client: client
        )
        XCTAssertEqual(result, VoiceEditPolicy.normalizedRewrite(
            reply, original: "Original text.", instruction: "wrap the result in a Swift code fence"
        ))
        XCTAssertEqual(result, reply)
    }

    func testEmptyInputAndInvalidTemperature_DoNotCallTheProvider() async {
        let client = EditChatSpy(messages: [])
        let invalid = [
            request(instruction: " \n"), request(selection: ""),
            request(temperature: .nan), request(temperature: -.infinity),
            request(temperature: -0.01), request(temperature: 1.01)
        ]
        for request in invalid {
            do {
                _ = try await DesktopVoiceEdit.rewrite(request, client: client)
                XCTFail("Invalid input must fail before any provider call.")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        XCTAssertTrue(client.calls.isEmpty)
    }

    func testMalformedAndEmptyReplies_AreNotSuccessfulRewrites() async {
        let responses: [[ChatMessage]] = [
            [], [.init(role: .user, content: "not an assistant")], [.init(role: .assistant, content: " \n")]
        ]
        for messages in responses {
            do {
                _ = try await DesktopVoiceEdit.rewrite(request(), client: EditChatSpy(messages: messages))
                XCTFail("An invalid reply must not become original-text-as-success.")
            } catch {
                XCTAssertEqual(error.localizedDescription, OpenRouterClientError.invalidResponse.localizedDescription)
            }
        }
    }

    func testCancelledUncooperativeReply_IsNeverReturned() async {
        let gate = EditReplyGate()
        let entered = expectation(description: "provider entered")
        let client = EditChatSpy(messages: [.init(role: .assistant, content: "Late rewrite.")], beforeReply: {
            entered.fulfill()
            await gate.wait()
        })
        let request = request()
        let work = Task { try await DesktopVoiceEdit.rewrite(request, client: client) }
        await fulfillment(of: [entered], timeout: 2)
        work.cancel()
        await gate.release()
        do {
            _ = try await work.value
            XCTFail("A provider that ignores cancellation must not deliver its reply.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func request(
        selection: String = "Original text.", instruction: String = "Make this shorter.", temperature: Double = 0.2
    ) -> DesktopVoiceEdit.Request {
        .init(selection: selection, instruction: instruction, model: "fixture/cloud-model", temperature: temperature)
    }
}

private actor EditReplyGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class EditChatSpy: ChatLLMClient, @unchecked Sendable {
    struct Call {
        let system: String?
        let messages: [ChatMessage]
        let model: String
        let temperature: Double
    }
    private let lock = NSLock()
    private let messages: [ChatMessage]
    private let beforeReply: (@Sendable () async -> Void)?
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }

    init(messages: [ChatMessage], beforeReply: (@Sendable () async -> Void)? = nil) {
        self.messages = messages
        self.beforeReply = beforeReply
    }
    func sendChat(
        systemPrompt: String?, messages: [ChatMessage], model: String, temperature: Double
    ) async throws -> ChatResponse {
        lock.withLock { recorded.append(.init(
            system: systemPrompt, messages: messages, model: model, temperature: temperature
        )) }
        await beforeReply?()
        return ChatResponse(messages: self.messages, finishReason: "stop", cost: nil, rawPayload: nil)
    }
}
