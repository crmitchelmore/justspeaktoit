import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakApp

final class PaidAccessBuildFlagTests: XCTestCase {
  func testBuildFlagMatchesCompilationCondition() {
    #if PAID_ACCESS
    XCTAssertTrue(PaidAccessFeature.isEnabled)
    #else
    XCTAssertFalse(PaidAccessFeature.isEnabled)
    #endif
  }
}

/// The fallback paths through ``PaidAccessProxyClient``.
///
/// Confirmed pre-dispatch refusals preserve the configured fallback. Submitted
/// uncertainty stops the operation rather than silently spending again.
final class PaidAccessProxyClientTests: XCTestCase {

    // MARK: - Doubles

    /// Stands in for the bring-your-own-key client, recording whether it ran.
    private actor StubFallback: PaidAccessFallbackClient {
        private(set) var transcribeCallCount = 0
        private(set) var chatCallCount = 0
        private(set) var lastTranscribedURL: URL?
        let transcript: String

        init(transcript: String) {
            self.transcript = transcript
        }

        func sendChat(
            systemPrompt: String?,
            messages: [ChatMessage],
            model: String,
            temperature: Double
        ) async throws -> ChatResponse {
            self.chatCallCount += 1
            return ChatResponse(
                messages: [ChatMessage(role: .assistant, content: self.transcript)],
                finishReason: "stop",
                cost: nil,
                rawPayload: nil
            )
        }

        nonisolated func sendChatStreaming(
            systemPrompt: String?,
            messages: [ChatMessage],
            model: String,
            temperature: Double
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func transcribeFile(
            at url: URL,
            model: String,
            language: String?
        ) async throws -> TranscriptionResult {
            self.transcribeCallCount += 1
            self.lastTranscribedURL = url
            return TranscriptionResult(
                text: self.transcript,
                segments: [],
                confidence: nil,
                duration: 1,
                modelIdentifier: model,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }

        func requiresRemoteAccess(for model: String) async -> Bool { true }
        func hasStoredAPIKey() async -> Bool { true }
    }

    /// A paid client that fails the test if anything reaches it. Every case here
    /// must be served without the paid service being called at all.
    private struct UnreachablePaidClient: PaidAccessClienting {
        func signInWithApple(
            identityToken: String,
            rawNonce: String,
            deviceLabel: String?
        ) async throws -> PaidAccessSession {
            throw PaidAccessError.invalidResponse
        }

        func refresh(session: PaidAccessSession) async throws -> PaidAccessSession {
            throw PaidAccessError.invalidResponse
        }

        func signOut(session: PaidAccessSession) async {}

        func entitlement(session: PaidAccessSession) async throws -> PaidAccessState {
            throw PaidAccessError.invalidResponse
        }

        func createCheckoutURL(session: PaidAccessSession) async throws -> URL {
            throw PaidAccessError.invalidResponse
        }

        func createBillingPortalURL(session: PaidAccessSession) async throws -> URL {
            throw PaidAccessError.invalidResponse
        }

        func syncStoreKitTransaction(
            session: PaidAccessSession,
            signedTransaction: String,
            signedRenewalInfo: String?
        ) async throws -> PaidEntitlement {
            throw PaidAccessError.invalidResponse
        }

        func transcribe(
            session: PaidAccessSession,
            audio: Data,
            contentType: String,
            language: String?,
            idempotencyKey: String
        ) async throws -> String {
            XCTFail("The paid service must not be called on a fallback path")
            throw PaidAccessError.invalidResponse
        }

        func postProcess(
            session: PaidAccessSession,
            text: String,
            systemPrompt: String?,
            temperature: Double,
            idempotencyKey: String
        ) async throws -> String {
            XCTFail("The paid service must not be called on a fallback path")
            throw PaidAccessError.invalidResponse
        }

        func liveTranscriptionRequest(
            session: PaidAccessSession,
            language: String?,
            sampleRate: Int
        ) throws -> URLRequest {
            XCTFail("The paid service must not be called on a fallback path")
            throw PaidAccessError.invalidResponse
        }
    }

    // MARK: - Fixtures

    private var scratch = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: self.scratch,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.scratch)
        try super.tearDownWithError()
    }

    private func entitledSession() -> PaidAccessSession {
        PaidAccessSession(
            accessToken: "access",
            accessTokenExpiresAt: Date().addingTimeInterval(3_600),
            refreshToken: "refresh",
            refreshTokenExpiresAt: Date().addingTimeInterval(86_400),
            userID: UUID().uuidString
        )
    }

    private func entitlement() -> PaidEntitlement {
        PaidEntitlement(
            status: .active,
            planID: "paid",
            provider: .stripe,
            currentPeriodEnd: Date().addingTimeInterval(86_400),
            cancelAtPeriodEnd: false,
            paidRoutingAvailable: true,
            usage: nil
        )
    }

    private func proxy(
        policy: PaidRoutingPolicy,
        fallback: StubFallback
    ) -> PaidAccessProxyClient {
        let entitlement = self.entitlement()
        let session = self.entitledSession()
        return PaidAccessProxyClient(
            fallback: fallback,
            paidClient: UnreachablePaidClient(),
            sessionProvider: { session },
            routerProvider: {
                PaidAccessRouter(
                    entitlement: entitlement,
                    policy: policy,
                    isPaidRoutingPreferred: true
                )
            }
        )
    }

    private var transcriptionPolicy: PaidRoutingPolicy {
        PaidRoutingPolicy(
            version: "2026-08-13",
            routes: [
                PaidRoute(
                    operation: .batchTranscription,
                    provider: "openrouter",
                    model: "google/gemini-2.0-flash-001",
                    displayName: "Gemini 2.0 Flash"
                )
            ]
        )
    }

    // MARK: - Conversion failure

    func testUnconvertibleRecording_fallsBackInsteadOfLosingTheDictation() async throws {
        // The endpoint takes WAV, so anything else is converted first. A file
        // that cannot be converted is still a recording the user has already
        // made: it must complete through their own client, not throw.
        let source = self.scratch.appendingPathComponent("broken.m4a")
        try Data("not audio at all".utf8).write(to: source)

        let fallback = StubFallback(transcript: "Served by the user's own key.")
        let proxy = self.proxy(policy: self.transcriptionPolicy, fallback: fallback)

        let result = try await proxy.transcribeFile(
            at: source,
            model: "google/gemini-2.0-flash-001",
            language: "en"
        )

        XCTAssertEqual(result.text, "Served by the user's own key.")
        let calls = await fallback.transcribeCallCount
        XCTAssertEqual(calls, 1)
        // The original recording is handed over untouched, so the fallback
        // transcribes what the user actually said.
        let forwarded = await fallback.lastTranscribedURL
        XCTAssertEqual(forwarded, source)
    }

    // MARK: - Routing failure

    func testRoutingError_fallsBackInsteadOfFailingTheRequest() async throws {
        // An entitled user whose policy publishes no route for this operation.
        // Resolving the route throws `unsupportedOperation`, and that must be
        // caught inside the same `do` that guards the request — it was once
        // thrown before the fallback could run, losing the recording.
        let emptyPolicy = PaidRoutingPolicy(version: "2026-08-13", routes: [])
        let fallback = StubFallback(transcript: "Still transcribed.")
        let proxy = self.proxy(policy: emptyPolicy, fallback: fallback)

        let wav = self.scratch.appendingPathComponent("recording.wav")
        try Data("RIFF....WAVE".utf8).write(to: wav)

        let result = try await proxy.transcribeFile(
            at: wav,
            model: "google/gemini-2.0-flash-001",
            language: nil
        )

        XCTAssertEqual(result.text, "Still transcribed.")
        let calls = await fallback.transcribeCallCount
        XCTAssertEqual(calls, 1)
    }

    func testRoutingError_completesCleanupThroughTheUsersOwnClient() async throws {
        // The same guarantee for post-processing: a routing failure costs the
        // paid model, never the text the user just dictated.
        let emptyPolicy = PaidRoutingPolicy(version: "2026-08-13", routes: [])
        let fallback = StubFallback(transcript: "Cleaned up locally.")
        let proxy = self.proxy(policy: emptyPolicy, fallback: fallback)

        let response = try await proxy.sendChat(
            systemPrompt: "Tidy this up",
            messages: [ChatMessage(role: .user, content: "some dictated words")],
            model: "openai/gpt-5-mini",
            temperature: 0.2
        )

        XCTAssertEqual(response.messages.last?.content, "Cleaned up locally.")
    }
}

extension PaidAccessProxyClientTests {
    func testSubmittedUncertaintyNeverCallsFallbackButConfirmedPreDispatchRefusalDoes() async throws {
        for batch in [false, true] {
            for code in ["outcome_unknown", "settlement_pending", "request_in_progress", "already_processed",
                         "unauthorized", "transport", "malformed", "paid_routing_disabled"] {
                try await self.assertSubmittedFallback(code: code, batch: batch)
            }
        }
    }

    private func assertSubmittedFallback(code: String, batch: Bool) async throws {
        let transport = StubURLProtocol.makeSession()
        defer { transport.invalidateAndCancel(); StubURLProtocol.reset() }
        let client = PaidAccessHTTPClient(baseURL: URL(string: "https://synthetic.invalid")!, session: transport)
        let entitlement = self.entitlement()
        let account = self.entitledSession()
        let operation: PaidOperation = batch ? .batchTranscription : .postProcessing
        let policy = PaidRoutingPolicy(version: "fixture", routes: [PaidRoute(
            operation: operation, provider: "openrouter", model: "fixed-provider-model", displayName: "Fixed"
        )])
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            if code == "transport" { return .fail(URLError(.networkConnectionLost)) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            let body = code == "malformed" ? "not-json" : "{\"error\":{\"code\":\"\(code)\"}}"
            return .respond(response, Data(body.utf8))
        }
        let fallback = StubFallback(transcript: "configured fallback")
        let proxy = PaidAccessProxyClient(fallback: fallback, paidClient: client,
                                         sessionProvider: { account }, routerProvider: {
            PaidAccessRouter(entitlement: entitlement, policy: policy, isPaidRoutingPreferred: true)
        })
        do {
            let text: String
            if batch {
                let wav = self.scratch.appendingPathComponent("original-attempt.wav")
                try Data("synthetic WAV upload".utf8).write(to: wav)
                text = try await proxy.transcribeFile(at: wav, model: "fixed-provider-model", language: nil).text
            } else {
                text = try await proxy.sendChat(systemPrompt: nil,
                    messages: [ChatMessage(role: .user, content: "fixture")],
                    model: "fixed-provider-model", temperature: 0.2).messages.last?.content ?? ""
            }
            XCTAssertEqual(code, "paid_routing_disabled")
            XCTAssertEqual(text, "configured fallback")
        } catch let error as PaidAccessError {
            XCTAssertNotEqual(code, "paid_routing_disabled")
            XCTAssertFalse(error.permitsSilentFallback)
        }
        let fallbackCalls: Int
        if batch {
            fallbackCalls = await fallback.transcribeCallCount
        } else {
            fallbackCalls = await fallback.chatCallCount
        }
        XCTAssertEqual(fallbackCalls, code == "paid_routing_disabled" ? 1 : 0, code)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testLocalMissingSessionFallsBackWithoutHandingAnythingToTransport() async throws {
        let transport = StubURLProtocol.makeSession()
        defer { transport.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in
            XCTFail("A locally missing session must never submit an operation")
            return .fail(URLError(.badServerResponse))
        }
        let fallback = StubFallback(transcript: "configured fallback")
        let entitlement = self.entitlement()
        let policy = PaidRoutingPolicy(version: "fixture", routes: [PaidRoute(
            operation: .postProcessing, provider: "openrouter", model: "fixed-provider-model", displayName: "Fixed"
        )])
        let proxy = PaidAccessProxyClient(fallback: fallback,
            paidClient: PaidAccessHTTPClient(baseURL: URL(string: "https://synthetic.invalid")!, session: transport),
            sessionProvider: { nil }, routerProvider: {
                PaidAccessRouter(entitlement: entitlement, policy: policy, isPaidRoutingPreferred: true)
            })
        let result = try await proxy.sendChat(systemPrompt: nil,
            messages: [ChatMessage(role: .user, content: "fixture")], model: "fixed-provider-model", temperature: 0.2)
        XCTAssertEqual(result.messages.last?.content, "configured fallback")
        let calls = await fallback.chatCallCount
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }
}
