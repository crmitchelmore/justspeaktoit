import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class PostProcessingRequestDiagnosticTests: XCTestCase {
    func testHeldStreamingFailureUsesCapturedModelAndFreshFallbackTemperature() async throws {
        let client = PostDiagnosticClient()
        var temperature = 0.2
        var streaming = true
        var selectedModel = "openai/gpt-4o-mini"
        let model = selectedModel
        var receipts: [RequestDiagnosticContext.PostProcessingObservation] = []
        var streamingReads = 0
        var temperatureReads = 0
        let exit = XCTestExpectation(description: "owned fallback operation exited")
        let task = Task { @MainActor in
            defer { exit.fulfill() }
            return await self.run(client, model: model, streaming: {
                streamingReads += 1
                return streaming
            }, temperature: {
                temperatureReads += 1
                return temperature
            }, observe: { receipts.append($0) })
        }
        self.own(task, client: client, exit: exit)
        await fulfillment(of: [client.entered], timeout: 2)
        XCTAssertEqual(client.streamCalls.map(\.temperature), [0.2])
        temperature = 0.8
        streaming = false
        selectedModel = "anthropic/claude-sonnet-4"
        client.finish(.failure(URLError(.timedOut)))
        let outcome = try await task.value.get()
        XCTAssertNotEqual(selectedModel, model)
        XCTAssertEqual(client.chatCalls.map(\.temperature), [0.8])
        XCTAssertEqual(client.streamCalls.map(\.model), [model])
        XCTAssertEqual(client.chatCalls.map(\.model), [model])
        XCTAssertEqual(streamingReads, 1)
        XCTAssertEqual(temperatureReads, 2)
        XCTAssertEqual(outcome.processed, "cleaned")
        XCTAssertEqual(outcome.response, client.response)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.first?.handoff?.options.streamingEnabled, true)
        XCTAssertEqual(receipts.last?.handoff?.options.streamingEnabled, false)
        XCTAssertEqual(receipts.last?.fallbackObserved, true)
        XCTAssertNil(receipts.last?.finalFailure)
        XCTAssertTrue(receipts.allSatisfy { $0.handoff?.observedProvider == nil })
    }

    func testStreamingSuccessPreservesReplacementUpdatesWithoutFallback() async throws {
        let client = PostDiagnosticClient()
        var receipts: [RequestDiagnosticContext.PostProcessingObservation] = []
        var updates: [String] = []
        let exit = XCTestExpectation(description: "owned stream success exited")
        let task = Task { @MainActor in
            defer { exit.fulfill() }
            return await self.run(client, streaming: { true }, observe: { receipts.append($0) },
                                  update: { updates.append($0) })
        }
        self.own(task, client: client, exit: exit)
        await fulfillment(of: [client.entered], timeout: 2)
        client.yield("clean")
        client.yield("ed")
        client.finish(.success(()))
        let outcome = try await task.value.get()
        XCTAssertEqual(updates, ["clean", "cleaned"])
        XCTAssertEqual(outcome.processed, "cleaned")
        XCTAssertNil(outcome.response)
        XCTAssertEqual(client.chatCalls.count, 0)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertNil(receipts.first?.fallbackObserved)
        XCTAssertNil(receipts.first?.finalFailure)
    }

    func testNonstreamPreferenceAndNonstreamClientEachInvokeOneRequest() async throws {
        for enabled in [false, true] {
            let client = PostDiagnosticNonstreamClient()
            var receipts: [RequestDiagnosticContext.PostProcessingObservation] = []
            let outcome = try await self.run(client, streaming: { enabled }, observe: { receipts.append($0) }).get()
            XCTAssertEqual(outcome.processed, "cleaned")
            XCTAssertEqual(client.calls, 1)
            XCTAssertEqual(receipts.count, 1)
            XCTAssertEqual(receipts.first?.handoff?.options.streamingEnabled, false)
            XCTAssertNil(receipts.first?.fallbackObserved)
        }
    }

    func testFinalErrorIdentityAndCanaryRemainInResultButNeverReport() async throws {
        let client = PostDiagnosticClient()
        let error = OpenRouterClientError.httpStatus(401, PostDiagnosticClient.canary)
        client.chatResult = .failure(error)
        client.finish(.failure(URLError(.timedOut)))
        var latest: RequestDiagnosticContext.PostProcessingObservation?
        let result = await self.run(client, streaming: { true }, observe: { latest = $0 })
        switch result {
        case .success: XCTFail("Original failure must remain a failure")
        case .failure(OpenRouterClientError.httpStatus(let status, let body)):
            XCTAssertEqual(status, 401)
            XCTAssertEqual(body, PostDiagnosticClient.canary)
        case .failure: XCTFail("The original typed error must be preserved")
        }
        XCTAssertEqual(latest?.finalFailure,
                       .init(stage: .postProcessing, code: .authentication, domain: .provider, httpStatus: 401))
        XCTAssertEqual(latest?.fallbackObserved, true)
        let report = IssueDiagnosticReport(observedHandoff: nil, postProcessingObservation: latest)
        XCTAssertFalse((report.body + report.jsonString + (report.issueURL?.absoluteString ?? ""))
            .contains(PostDiagnosticClient.canary))
    }

    func testNilObserverKeepsOriginalResponseCostPayloadAndFallbackBehavior() async throws {
        let client = PostDiagnosticClient()
        client.finish(.failure(CancellationError()))
        let outcome = try await self.run(client, streaming: { true }, observe: nil).get()
        XCTAssertEqual(client.streamCalls.count, 1)
        XCTAssertEqual(client.chatCalls.count, 1)
        XCTAssertEqual(outcome.original, PostDiagnosticClient.canary)
        XCTAssertEqual(outcome.response, client.response)
        XCTAssertEqual(outcome.promptPayload?.systemPrompt, PostDiagnosticClient.canary)
    }

    func testCancelledStreamTerminationDoesNotInventFallback() async throws {
        let client = PostDiagnosticClient()
        let done = XCTestExpectation(description: "cancelled stream returned")
        let exit = XCTestExpectation(description: "cancelled delegate exited")
        let task = Task { @MainActor in
            defer { done.fulfill(); exit.fulfill() }
            return await self.run(client, streaming: { true }, observe: nil)
        }
        self.own(task, client: client, exit: exit)
        await fulfillment(of: [client.entered], timeout: 2)
        task.cancel()
        // Iterator cancellation can return nil; do not manufacture an error
        // and assume the streaming catch/fallback must run.
        let settled = await XCTWaiter.fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(settled, .completed)
        guard settled == .completed else { return }
        let outcome = try await task.value.get()
        XCTAssertEqual(client.streamCalls.count, 1)
        XCTAssertEqual(client.chatCalls.count, 0)
        XCTAssertEqual(outcome.processed, PostDiagnosticClient.canary)
        XCTAssertNil(outcome.response)
    }

    func run(
        _ client: ChatLLMClient, model: String = "openai/gpt-4o-mini", streaming: @escaping () -> Bool,
        temperature: @escaping () -> Double = { 0.3 },
        observe: ((RequestDiagnosticContext.PostProcessingObservation) -> Void)?, update: ((String) -> Void)? = nil
    ) async -> Result<PostProcessingOutcome, Error> {
        await PostProcessingManager.performRemoteProcess(
            client: client, rawText: PostDiagnosticClient.canary,
            promptPayload: .init(modelIdentifier: model, customPrompt: nil, systemPrompt: PostDiagnosticClient.canary,
                                 userPrompt: PostDiagnosticClient.canary),
            settings: (streamingEnabled: streaming, temperature: temperature),
            delivery: .init(log: SpeakLogger.logger(category: "OwnedPostProcessingFixture"),
                       streamingUpdate: update, diagnostic: observe)
        )
    }

    private func own(_ task: Task<Result<PostProcessingOutcome, Error>, Never>, client: PostDiagnosticClient,
                     exit: XCTestExpectation) {
        addTeardownBlock { @MainActor in
            task.cancel()
            client.finish(.failure(CancellationError()))
            client.releaseChat(.failure(CancellationError()))
            let result = await XCTWaiter.fulfillment(of: [exit], timeout: 2)
            XCTAssertEqual(result, .completed)
        }
    }
}

/// All calls are made by the MainActor remote delegate. No singleton, settings,
/// credential, filesystem, model runtime or provider is constructed.
final class PostDiagnosticClient: StreamingChatLLMClient {
    struct Call { let model: String; let temperature: Double }
    static let canary = "PRIVATE_POLISH_token=user@example.com/path"
    let entered = XCTestExpectation(description: "owned stream entered")
    let chatEntered = XCTestExpectation(description: "owned nonstream chat entered")
    let response = ChatResponse(messages: [.init(role: .assistant, content: "cleaned")], finishReason: "stop",
                                cost: .init(inputTokens: 1, outputTokens: 2, totalCost: 3, currency: "USD"),
                                rawPayload: PostDiagnosticClient.canary)
    private let lock = NSLock()
    private var recordedStreamCalls: [Call] = []
    private var recordedChatCalls: [Call] = []
    private var heldChat = false
    private var result: Result<ChatResponse, Error>?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var completion: Result<Void, Error>?
    private var chatContinuation: CheckedContinuation<ChatResponse, Error>?
    private var chatCompletion: Result<ChatResponse, Error>?

    var streamCalls: [Call] { self.lock.withLock { self.recordedStreamCalls } }
    var chatCalls: [Call] { self.lock.withLock { self.recordedChatCalls } }
    var hasPendingChat: Bool { self.lock.withLock { self.chatContinuation != nil } }
    var holdsChat: Bool {
        get { self.lock.withLock { self.heldChat } }
        set { self.lock.withLock { self.heldChat = newValue } }
    }
    var chatResult: Result<ChatResponse, Error>? {
        get { self.lock.withLock { self.result } }
        set { self.lock.withLock { self.result = newValue } }
    }

    func sendChatStreaming(systemPrompt: String?, messages: [ChatMessage], model: String,
                           temperature: Double) -> AsyncThrowingStream<String, Error> {
        self.lock.withLock { self.recordedStreamCalls.append(.init(model: model, temperature: temperature)) }
        return AsyncThrowingStream { continuation in
            let completion = self.lock.withLock { () -> Result<Void, Error>? in
                if let completion = self.completion { return completion }
                self.continuation = continuation
                return nil as Result<Void, Error>?
            }
            if let completion { Self.finish(continuation, with: completion) }
            self.entered.fulfill()
        }
    }

    func sendChat(systemPrompt: String?, messages: [ChatMessage], model: String,
                  temperature: Double) async throws -> ChatResponse {
        let held = self.lock.withLock {
            self.recordedChatCalls.append(.init(model: model, temperature: temperature))
            return self.heldChat
        }
        guard held else {
            self.chatEntered.fulfill()
            return try self.chatResult?.get() ?? self.response
        }
        // Intentionally no cancellation handler: this owned client can ignore
        // cancellation until explicit release, including release-before-arrival.
        return try await withCheckedThrowingContinuation { continuation in
            let completed = self.lock.withLock { () -> Result<ChatResponse, Error>? in
                if let completed = self.chatCompletion { return completed }
                self.chatContinuation = continuation
                return nil as Result<ChatResponse, Error>?
            }
            self.chatEntered.fulfill()
            if let completed { continuation.resume(with: completed) }
        }
    }

    func releaseChat(_ result: Result<ChatResponse, Error>? = nil) {
        let pending = self.lock.withLock {
            () -> (CheckedContinuation<ChatResponse, Error>?, Result<ChatResponse, Error>) in
            let result = result ?? self.result ?? .success(self.response)
            guard self.chatCompletion == nil else { return (nil, result) }
            self.chatCompletion = result
            let continuation = self.chatContinuation
            self.chatContinuation = nil
            return (continuation, result)
        }
        pending.0?.resume(with: pending.1)
    }

    func yield(_ text: String) {
        let continuation = self.lock.withLock { self.continuation }
        continuation?.yield(text)
    }

    func finish(_ result: Result<Void, Error>) {
        let continuation = self.lock.withLock { () -> AsyncThrowingStream<String, Error>.Continuation? in
            guard self.completion == nil else { return nil }
            self.completion = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        if let continuation { Self.finish(continuation, with: result) }
    }

    private static func finish(_ continuation: AsyncThrowingStream<String, Error>.Continuation,
                               with result: Result<Void, Error>) {
        switch result {
        case .success: continuation.finish()
        case .failure(let error): continuation.finish(throwing: error)
        }
    }
}

final class PostDiagnosticNonstreamClient: ChatLLMClient {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { self.lock.withLock { self.count } }
    func sendChat(systemPrompt: String?, messages: [ChatMessage], model: String,
                  temperature: Double) async throws -> ChatResponse {
        self.lock.withLock { self.count += 1 }
        return .init(messages: [.init(role: .assistant, content: "cleaned")], finishReason: "stop",
                     cost: nil, rawPayload: nil)
    }
}
