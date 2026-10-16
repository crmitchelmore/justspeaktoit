import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopLivePolishClientTests: XCTestCase {
    func testRemoteClient_ReceivesExactPromptFullUnicodeSnapshotModelAndZeroTemperature() async throws {
        let client = PolishChatSpy(messages: [.init(role: .assistant, content: " Cleaned. \n")])
        let model = ModelCatalog.defaultFastTextModel
        let text = "raw 👩🏽‍💻 café\nsecond line"
        let result = try await DesktopPostProcessing.polishLive(text: text, model: model, localLLM: nil, client: client)
        XCTAssertEqual(result, "Cleaned.")
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls[0].system, LivePolishPolicy.systemPrompt)
        XCTAssertEqual(client.calls[0].messages.map(\.role), [.user])
        XCTAssertEqual(client.calls[0].messages.map(\.content), ["Clean this text:\n" + text])
        XCTAssertEqual(client.calls[0].model, model)
        XCTAssertEqual(client.calls[0].temperature, 0)
    }

    func testMalformedAndEmptyResponse_ThrowInsteadOfFallingBackToRaw() async {
        let responses: [[ChatMessage]] = [
            [], [.init(role: .user, content: "not an assistant")], [.init(role: .assistant, content: " \n ")]
        ]
        for messages in responses {
            do {
                _ = try await DesktopPostProcessing.polishLive(
                    text: "raw", model: ModelCatalog.defaultFastTextModel, localLLM: nil,
                    client: PolishChatSpy(messages: messages)
                )
                XCTFail("An unusable response must not become raw-as-success")
            } catch {
                XCTAssertEqual(error.localizedDescription, LivePolishError.invalidResponse.localizedDescription)
            }
        }
    }

    func testLocalClient_UsesExistingEngineWithoutChatAndRejectsBuiltInRules() async throws {
        let local = PolishLocalSpy()
        let chat = PolishChatSpy(messages: [])
        let model = LocalPostProcessingModel.huggingFaceModelID(repoID: "fixture/model", filename: "model.gguf")
        XCTAssertTrue(LocalPostProcessingModel.isDownloadedModelID(model))
        let result = try await DesktopPostProcessing.polishLive(
            text: "local raw", model: model, localLLM: local, client: chat
        )
        XCTAssertEqual(result, "Local cleaned.")
        XCTAssertEqual(local.calls.first?.model, model)
        XCTAssertEqual(local.calls.first?.system, LivePolishPolicy.systemPrompt)
        XCTAssertEqual(local.calls.first?.user, "Clean this text:\nlocal raw")
        XCTAssertEqual(local.calls.first?.temperature, 0)
        XCTAssertTrue(chat.calls.isEmpty)
        do {
            _ = try await DesktopPostProcessing.polishLive(
                text: "raw", model: LocalPostProcessingModel.builtInRulesModelID, localLLM: local, client: chat
            )
            XCTFail("Built-in rules must not be advertised as a live LLM")
        } catch {
            XCTAssertEqual(error.localizedDescription, LivePolishError.unsupportedModel.localizedDescription)
        }
        XCTAssertEqual(local.calls.count, 1)
        XCTAssertTrue(chat.calls.isEmpty)
    }

    func testSilentInputAndUnsupportedModel_DoNotCallEitherClient() async throws {
        let local = PolishLocalSpy()
        let chat = PolishChatSpy(messages: [])
        let silent = try await DesktopPostProcessing.polishLive(
            text: " \n ", model: ModelCatalog.defaultFastTextModel, localLLM: local, client: chat
        )
        XCTAssertEqual(silent, "")
        do {
            _ = try await DesktopPostProcessing.polishLive(
                text: "raw", model: "unknown/model", localLLM: local, client: chat
            )
            XCTFail("Unknown models must not be guessed")
        } catch {
            XCTAssertEqual(error.localizedDescription, LivePolishError.unsupportedModel.localizedDescription)
        }
        XCTAssertTrue(chat.calls.isEmpty)
        XCTAssertTrue(local.calls.isEmpty)
    }
}

private final class PolishChatSpy: ChatLLMClient, @unchecked Sendable {
    struct Call {
        let system: String?
        let messages: [ChatMessage]
        let model: String
        let temperature: Double
    }
    private let lock = NSLock()
    private let messages: [ChatMessage]
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    init(messages: [ChatMessage]) { self.messages = messages }
    func sendChat(
        systemPrompt: String?, messages: [ChatMessage], model: String, temperature: Double
    ) async throws -> ChatResponse {
        lock.withLock { recorded.append(.init(
            system: systemPrompt, messages: messages, model: model, temperature: temperature
        )) }
        return ChatResponse(messages: self.messages, finishReason: "stop", cost: nil, rawPayload: nil)
    }
}

private final class PolishLocalSpy: DesktopLocalLLMEngine, @unchecked Sendable {
    struct Call {
        let model: String
        let system: String
        let user: String
        let temperature: Double
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    func complete(
        modelIdentifier: String, systemPrompt: String, userPrompt: String, temperature: Double
    ) async throws -> String {
        lock.withLock { recorded.append(.init(
            model: modelIdentifier, system: systemPrompt, user: userPrompt, temperature: temperature
        )) }
        return "Local cleaned."
    }
}
